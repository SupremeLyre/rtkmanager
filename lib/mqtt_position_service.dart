import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'map_layer_controller.dart';
import 'position_data.dart';
import 'mqtt_position_archive.dart';

enum MqttPositionConnection {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

class MqttPositionSettings {
  const MqttPositionSettings({
    this.host = '121.37.254.162',
    this.port = 1883,
    this.topic = 'app',
    this.username = '',
    this.password = '',
    this.tls = false,
  });
  final String host;
  final int port;
  final String topic;
  final String username;
  final String password;
  final bool tls;
}

class MqttPositionFix {
  const MqttPositionFix({
    required this.deviceId,
    required this.position,
    required this.gga,
    required this.receivedAt,
    this.sendTime,
  });
  final String deviceId;
  final PositionHistoryPoint position;
  final String gga;
  final DateTime receivedAt;
  final DateTime? sendTime;

  static MqttPositionFix? parse(String payload, {DateTime? receivedAt}) {
    try {
      if (payload.length > 16384) return null;
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return null;
      final id = json['device_id'];
      final raw = json['gga'] ?? json['GGA'];
      if (id is! String || id.trim().isEmpty || raw is! String) return null;
      final gga = raw.trim();
      if (id.length > 128 || gga.length > 1024) return null;
      final match = RegExp(
        r'^\$[A-Z]{2}GGA,[^\r\n]*\*([0-9A-Fa-f]{2})$',
      ).firstMatch(gga);
      if (match == null) return null;
      final checksum = gga
          .substring(1, gga.length - 3)
          .codeUnits
          .fold(0, (a, b) => a ^ b);
      if (checksum != int.parse(match.group(1)!, radix: 16)) return null;
      final parts = gga.split(',');
      if (parts.length < 15) return null;
      if (!RegExp(r'^\d{6}(\.\d+)?$').hasMatch(parts[1]) ||
          int.parse(parts[1].substring(0, 2)) > 23 ||
          int.parse(parts[1].substring(2, 4)) > 59 ||
          double.parse(parts[1].substring(4)) >= 61) {
        return null;
      }
      final lat = double.tryParse(parts[2]);
      final lon = double.tryParse(parts[4]);
      final dop = double.tryParse(parts[8]);
      final alt = double.tryParse(parts[9]);
      if (lat == null ||
          lon == null ||
          dop == null ||
          alt == null ||
          !lat.isFinite ||
          !lon.isFinite ||
          !dop.isFinite ||
          !alt.isFinite ||
          lat < 0 ||
          lon < 0 ||
          lat > 9000 ||
          lon > 18000 ||
          lat % 100 >= 60 ||
          lon % 100 >= 60 ||
          dop < 0 ||
          !['N', 'S'].contains(parts[3]) ||
          !['E', 'W'].contains(parts[5])) {
        return null;
      }
      // The common parser handles the same GGA coordinates as serial/offline input.
      final position = parsePositionLine(gga, ggaOnly: true);
      if (position == null) return null;
      return MqttPositionFix(
        deviceId: id.trim(),
        position: position,
        gga: gga,
        receivedAt: receivedAt ?? DateTime.now(),
        sendTime: json['send_time'] is String
            ? DateTime.tryParse(json['send_time'])?.toUtc()
            : null,
      );
    } on FormatException {
      return null;
    }
  }
}

class MqttDeviceTrack {
  final ListQueue<MqttPositionFix> _points = ListQueue();
  Iterable<MqttPositionFix> get points => _points;
  int get length => _points.length;
  MqttPositionFix? get latest => _points.isEmpty ? null : _points.last;
}

/// Receives JSON positions without publishing commands or owning map widgets.
class MqttPositionService extends ChangeNotifier {
  MqttPositionService({
    this.maxPointsPerDevice = 5000,
    this.maxTotalPoints = 20000,
    this.maxDevices = 64,
    MqttPositionArchive? archive,
  }) : assert(maxPointsPerDevice > 0),
       assert(maxTotalPoints > 0),
       assert(maxDevices > 0),
       archive = archive ?? MqttPositionArchive() {
    this.archive.addListener(_archiveUpdated);
  }

  final MqttPositionArchive archive;
  void _archiveUpdated() {
    if (!_disposed) notifyListeners();
  }

  final int maxPointsPerDevice;
  final int maxTotalPoints;
  final int maxDevices;
  int _totalPoints = 0;
  int get cachedPoints => _totalPoints;
  int evictedPoints = 0;
  int evictedDevices = 0;
  String get cacheDescription =>
      '地图缓存：每台最多 $maxPointsPerDevice 点，总计最多 $maxTotalPoints 点，最多 $maxDevices 台最近活跃设备。旧轨迹移出内存，完整接收记录保存在本地日志中。';
  final MapLayerController layers = MapLayerController();
  final Map<String, MqttDeviceTrack> _tracks = {};
  Map<String, MqttDeviceTrack> get tracks => UnmodifiableMapView(_tracks);
  MqttPositionSettings settings = const MqttPositionSettings();
  MqttPositionConnection connection = MqttPositionConnection.disconnected;
  String? error;
  int receivedMessages = 0;
  int ignoredMessages = 0;
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _subscription;
  Timer? _subscribeTimeout;
  bool _disposed = false;

  bool get isActive => [
    MqttPositionConnection.connecting,
    MqttPositionConnection.connected,
    MqttPositionConnection.reconnecting,
  ].contains(connection);

  String get statusLabel => switch (connection) {
    MqttPositionConnection.disconnected => '未连接',
    MqttPositionConnection.connecting => '连接 / 订阅中',
    MqttPositionConnection.connected => '已连接',
    MqttPositionConnection.reconnecting => '正在重连',
    MqttPositionConnection.failed => '连接失败',
  };

  Future<void> connect(MqttPositionSettings value) async {
    _closeClient();
    settings = value;
    error = null;
    connection = MqttPositionConnection.connecting;
    notifyListeners();
    final id =
        'rtkm_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${Random.secure().nextInt(65536).toRadixString(36)}';
    final client = MqttServerClient.withPort(value.host, id, value.port)
      ..setProtocolV311()
      ..logging(on: false)
      ..secure = value.tls
      ..keepAlivePeriod = 20
      ..connectTimeoutPeriod = 8000
      ..socketTimeout = 8000
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..connectionMessage = MqttConnectMessage()
          .withClientIdentifier(id)
          .startClean();
    _client = client;
    bool current() => !_disposed && identical(_client, client);
    void waitForSubscription() {
      _subscribeTimeout?.cancel();
      _subscribeTimeout = Timer(const Duration(seconds: 10), () {
        if (current()) _fail('主题订阅超时，请检查主题和访问权限。');
      });
    }

    client.onSubscribed = (_) {
      if (!current()) return;
      _subscribeTimeout?.cancel();
      connection = MqttPositionConnection.connected;
      error = null;
      notifyListeners();
    };
    client.onSubscribeFail = (_) {
      if (current()) _fail('服务器拒绝订阅，请检查主题和账号权限。');
    };
    client.onAutoReconnect = () {
      if (!current()) return;
      _subscribeTimeout?.cancel();
      connection = MqttPositionConnection.reconnecting;
      notifyListeners();
    };
    client.onAutoReconnected = () {
      if (!current()) return;
      waitForSubscription();
    };
    client.onDisconnected = () {
      if (current()) _fail('连接已断开，请重新连接。');
    };
    try {
      final status = await client.connect(
        value.username.isEmpty ? null : value.username,
        value.password.isEmpty ? null : value.password,
      );
      if (!current()) {
        client.disconnect();
        return;
      }
      if (status?.state != MqttConnectionState.connected) {
        _fail('连接被拒绝：${status?.returnCode?.name ?? '未知原因'}');
        return;
      }
      _subscription = client.updates!.listen((messages) {
        if (!current()) return;
        for (final message in messages) {
          if (message.payload is! MqttPublishMessage) continue;
          final publish = message.payload as MqttPublishMessage;
          try {
            ingestPayload(utf8.decode(publish.payload.message));
          } on FormatException {
            receivedMessages++;
            ignoredMessages++;
            notifyListeners();
          }
        }
      });
      waitForSubscription();
      if (client.subscribe(value.topic, MqttQos.atMostOnce) == null) {
        _fail('无法订阅，请检查主题格式。');
      }
    } catch (_) {
      if (current()) _fail('无法连接 MQTT，请检查地址、端口、TLS 和账号。');
    }
  }

  /// Accepts the exact UTF-8 JSON payload from a subscribed MQTT publication.
  bool ingestPayload(String payload) {
    if (_disposed) return false;
    receivedMessages++;
    final fix = MqttPositionFix.parse(payload);
    if (fix == null) {
      ignoredMessages++;
      notifyListeners();
      return false;
    }
    final track = _tracks[fix.deviceId] ?? MqttDeviceTrack();
    final previous = track.latest;
    if (previous != null &&
        ((previous.gga == fix.gga && previous.sendTime == fix.sendTime) ||
            (previous.sendTime != null &&
                fix.sendTime != null &&
                fix.sendTime!.isBefore(previous.sendTime!)))) {
      ignoredMessages++;
      notifyListeners();
      return false;
    }
    archive.record({
      'device_id': fix.deviceId,
      'send_time': fix.sendTime?.toIso8601String(),
      'received_at': fix.receivedAt.toUtc().toIso8601String(),
      'gga': fix.gga,
    }, fix.receivedAt);
    track._points.add(fix);
    _totalPoints++;
    if (track.length > maxPointsPerDevice) {
      track._points.removeFirst();
      _totalPoints--;
      evictedPoints++;
    }
    // Map order is least-recently-active first; identity metadata is bounded too.
    _tracks.remove(fix.deviceId);
    _tracks[fix.deviceId] = track;
    if (_tracks.length > maxDevices) {
      final oldestId = _tracks.keys.first;
      final removed = _tracks.remove(oldestId)!;
      _totalPoints -= removed.length;
      evictedPoints += removed.length;
      evictedDevices++;
      layers.removeLayer(oldestId);
    }
    while (_totalPoints > maxTotalPoints) {
      MqttDeviceTrack? oldest;
      for (final candidate in _tracks.values) {
        if (candidate._points.isNotEmpty &&
            (oldest == null ||
                candidate._points.first.receivedAt.isBefore(
                  oldest._points.first.receivedAt,
                ))) {
          oldest = candidate;
        }
      }
      oldest!._points.removeFirst();
      _totalPoints--;
      evictedPoints++;
    }
    layers.ensureLayer(fix.deviceId);
    notifyListeners();
    return true;
  }

  void clearTracks() {
    for (final track in _tracks.values) {
      track._points.clear();
    }
    _totalPoints = 0;
    evictedPoints = evictedDevices = 0;
    receivedMessages = ignoredMessages = 0;
    // Keep layer identities, colors and visibility for the continuing stream.
    notifyListeners();
  }

  void _fail(String message) {
    _closeClient();
    error = message;
    connection = MqttPositionConnection.failed;
    notifyListeners();
  }

  void disconnect() {
    _closeClient();
    unawaited(archive.flush());
    connection = MqttPositionConnection.disconnected;
    error = null;
    notifyListeners();
  }

  void _closeClient() {
    final client = _client;
    _client = null;
    _subscribeTimeout?.cancel();
    _subscription?.cancel();
    _subscription = null;
    client?.disconnect();
  }

  @override
  void dispose() {
    _disposed = true;
    _closeClient();
    layers.dispose();
    archive.removeListener(_archiveUpdated);
    archive.dispose();
    super.dispose();
  }
}
