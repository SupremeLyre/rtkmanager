import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum GnssBleConnection { disconnected, connecting, connected }

class GnssBleDevice {
  const GnssBleDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });
  final String id;
  final String name;
  final int rssi;

  bool get hasName => name.trim().isNotEmpty && name.trim() != '未命名设备';
}

/// Receives the ESP32 softAP firmware's Read + Notify GNSS characteristic.
class GnssBleService extends ChangeNotifier {
  GnssBleService({MethodChannel? methods, Stream<dynamic>? events})
    : _methods = methods ?? const MethodChannel('rtkmanager/gnss_ble') {
    _subscription =
        (events ??
                const EventChannel(
                  'rtkmanager/gnss_ble/events',
                ).receiveBroadcastStream())
            .listen(_onEvent, onError: _onStreamError);
  }

  final MethodChannel _methods;
  late final StreamSubscription<dynamic> _subscription;
  final _gga = StreamController<String>.broadcast(sync: true);
  final _devices = <String, GnssBleDevice>{};
  Stream<String> get ggaStream => _gga.stream;
  // Map insertion order keeps each device in place when its RSSI changes.
  List<GnssBleDevice> get devices => _devices.values.toList();

  /// Search covers all discoveries, including unnamed devices, without changing
  /// discovery order or excluding receivers that omit advertised service UUIDs.
  List<GnssBleDevice> filteredDevices({
    String query = '',
    bool includeUnnamed = false,
  }) {
    final text = query.trim().toLowerCase();
    final address = text.replaceAll(RegExp(r'[\s:-]'), '');
    return _devices.values.where((device) {
      if (text.isEmpty) return includeUnnamed || device.hasName;
      return device.name.toLowerCase().contains(text) ||
          (address.isNotEmpty &&
              device.id
                  .toLowerCase()
                  .replaceAll(RegExp(r'[\s:-]'), '')
                  .contains(address));
    }).toList();
  }

  GnssBleConnection connection = GnssBleConnection.disconnected;
  GnssBleDevice? device;
  bool scanning = false;
  bool requestingScan = false;
  String? error;
  int ggaCount = 0;
  int? mtu;
  String? latestGga;
  DateTime? lastReceived;
  bool _disposed = false;
  int _scanRequest = 0;
  int _connectionRequest = 0;
  bool get isActive => connection != GnssBleConnection.disconnected;

  Future<void> startScan() async {
    if (_disposed || isActive || requestingScan || scanning) return;
    final request = ++_scanRequest;
    _devices.clear();
    error = null;
    requestingScan = true;
    notifyListeners();
    try {
      await _methods.invokeMethod<void>('startScan');
    } catch (e) {
      if (!_disposed && request == _scanRequest) error = _errorText(e);
    } finally {
      if (!_disposed && request == _scanRequest) {
        requestingScan = false;
        notifyListeners();
      }
    }
  }

  Future<void> stopScan() async {
    if (_disposed) return;
    ++_scanRequest;
    requestingScan = false;
    scanning = false;
    await _command('stopScan');
  }

  Future<void> connect(GnssBleDevice selected) async {
    if (_disposed || isActive) return;
    final request = ++_connectionRequest;
    // Lock the UI before awaiting scan cancellation, preventing duplicate connects.
    connection = GnssBleConnection.connecting;
    device = selected;
    error = null;
    ggaCount = 0;
    latestGga = null;
    lastReceived = null;
    mtu = null;
    notifyListeners();
    await stopScan();
    if (_disposed ||
        request != _connectionRequest ||
        connection != GnssBleConnection.connecting) {
      return;
    }
    if (!await _command('connect', {'id': selected.id}) &&
        !_disposed &&
        request == _connectionRequest) {
      connection = GnssBleConnection.disconnected;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    ++_connectionRequest;
    await _command('disconnect');
    if (!_disposed) {
      connection = GnssBleConnection.disconnected;
      notifyListeners();
    }
  }

  Future<void> openSettings() => _command('openSettings');

  Future<bool> _command(String method, [Map<String, Object>? arguments]) async {
    try {
      await _methods.invokeMethod<void>(method, arguments);
      return true;
    } catch (e) {
      if (!_disposed) error = _errorText(e);
      return false;
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  String _errorText(Object error) => error is PlatformException
      ? error.message ?? '蓝牙操作失败，请重试'
      : '蓝牙不可用，请检查手机蓝牙设置后重试';

  void _onStreamError(Object exception) {
    if (_disposed) return;
    error = _errorText(exception);
    scanning = false;
    connection = GnssBleConnection.disconnected;
    notifyListeners();
  }

  void _onEvent(dynamic event) {
    if (_disposed || event is! Map) return;
    switch (event['type']) {
      case 'device':
        final id = event['id'] as String;
        final name = (event['name'] as String).trim();
        _devices[id] = GnssBleDevice(
          id: id,
          // Scan responses can supply a name that later advertisements omit.
          name: name.isEmpty || name == '未命名设备'
              ? _devices[id]?.name ?? '未命名设备'
              : name,
          rssi: event['rssi'] as int,
        );
      case 'scanning':
        scanning = event['value'] == true;
      case 'state':
        connection = switch (event['state']) {
          'connected' => GnssBleConnection.connected,
          'disconnected' => GnssBleConnection.disconnected,
          _ => GnssBleConnection.connecting,
        };
        mtu = event['mtu'] as int?;
        error = event['message'] as String?;
      case 'data':
        if (connection != GnssBleConnection.connected) return;
        final sentences = decodeGnssNotification(
          (event['bytes'] as List).cast<int>(),
        );
        if (sentences.isEmpty) return;
        for (final sentence in sentences) {
          latestGga = sentence;
          lastReceived = DateTime.now();
          ggaCount++;
          _gga.add(sentence);
        }
      case 'error':
        error = event['message'] as String?;
      default:
        return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Cancelling the native event channel also stops scanning and closes GATT.
    unawaited(_subscription.cancel());
    unawaited(_gga.close());
    super.dispose();
  }
}

/// Each firmware notification contains complete ASCII NMEA with CRLF. It may
/// omit *HH, but when present the checksum must match before plotting a fix.
List<String> decodeGnssNotification(List<int> bytes) {
  if (bytes.isEmpty || bytes.any((byte) => byte < 0 || byte > 127)) return [];
  final text = ascii.decode(bytes);
  if (!text.endsWith('\r\n')) return [];
  final sentences = <String>[];
  for (final line in text.split('\r\n')) {
    if (!(line.startsWith(r'$GPGGA,') ||
        line.startsWith(r'$GNGGA,') ||
        line.startsWith(r'$GBGGA,'))) {
      continue;
    }
    if (line.length > 254 || line.split(',').length < 15) continue;
    if (line.codeUnits.any((byte) => byte < 32 || byte > 126)) continue;
    final marker = line.indexOf('*');
    if (marker != -1) {
      if (marker != line.length - 3) continue;
      final expected = int.tryParse(line.substring(marker + 1), radix: 16);
      var actual = 0;
      for (final byte in line.substring(1, marker).codeUnits) {
        actual ^= byte;
      }
      if (expected != actual) continue;
    }
    sentences.add(line);
  }
  return sentences;
}
