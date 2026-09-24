import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/map_layer_controller.dart';
import 'package:rtkmanager/mqtt_position_service.dart';
import 'package:rtkmanager/mqtt_position_archive.dart';

String testGga({
  int second = 0,
  int status = 4,
  String lat = '4807.038000',
  String talker = 'GP',
}) {
  final body =
      '${talker}GGA,1007${second.toString().padLeft(2, '0')}.023,$lat,N,01131.000000,E,$status,12,0.8,545.400,M,,M,,';
  final checksum = body.codeUnits.fold(0, (a, b) => a ^ b);
  return '\$$body*${checksum.toRadixString(16).padLeft(2, '0').toUpperCase()}\r\n';
}

String testPayload(
  String id, {
  int second = 0,
  int status = 4,
  bool upper = false,
  String? time = '2026-01-08T10:07:04.125Z',
}) => jsonEncode({
  'device_id': id,
  'send_time': time,
  upper ? 'GGA' : 'gga': testGga(second: second, status: status),
  'rmc': null,
});

Future<void> waitUntil(bool Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 12));
  while (!check() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(check(), isTrue);
}

late Directory archiveDirectory;
MqttPositionArchive testArchive() =>
    MqttPositionArchive(directory: () async => archiveDirectory);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    archiveDirectory = Directory.systemTemp.createTempSync(
      'mqtt_archive_test_',
    );
  });
  tearDown(() {
    if (archiveDirectory.existsSync()) {
      archiveDirectory.deleteSync(recursive: true);
    }
  });
  test('firmware JSON decodes GGA, identity and separate timestamps', () {
    final received = DateTime.utc(2026, 1, 8, 10, 7, 5);
    final fix = MqttPositionFix.parse(
      testPayload('fusion_a'),
      receivedAt: received,
    )!;
    expect(fix.deviceId, 'fusion_a');
    expect(fix.position.posInfo!.utcTime, '10:07:00.023');
    expect(fix.sendTime, DateTime.utc(2026, 1, 8, 10, 7, 4, 125));
    expect(fix.receivedAt, received);
    expect(fix.position.location.latitude, closeTo(48.1173, 1e-7));
    expect(fix.position.location.longitude, closeTo(11.516666667, 1e-7));
    expect(fix.position.posInfo!.altitude, 545.4);
    expect(fix.position.posInfo!.satellites, 12);
    expect(
      MqttPositionFix.parse(
        testPayload('fusion_b', upper: true, time: null),
      )!.sendTime,
      isNull,
    );
  });

  test(
    'invalid JSON, checksums, no-fix and non-finite coordinates are ignored',
    () {
      for (final payload in [
        'not JSON',
        '[]',
        '{}',
        jsonEncode({'device_id': 123, 'gga': testGga()}),
        testPayload(''),
        testPayload('a', status: 0),
        jsonEncode({
          'device_id': 'a',
          'gga': testGga().replaceFirst('0.8', '0.9'),
        }),
        jsonEncode({'device_id': 'a', 'gga': testGga(lat: 'NaN')}),
        jsonEncode({'device_id': 'a', 'gga': testGga(lat: '4860.000')}),
      ]) {
        expect(MqttPositionFix.parse(payload), isNull, reason: payload);
      }
      expect(
        MqttPositionFix.parse(
          jsonEncode({
            'device_id': 'a',
            'gga': testGga(talker: 'GA', lat: '0000.000'),
          }),
        ),
        isNotNull,
      );
    },
  );

  test(
    'device tracks are independent, bounded and retain visibility/colors',
    () {
      final service = MqttPositionService(
        maxPointsPerDevice: 3,
        archive: testArchive(),
      );
      addTearDown(() async {
        service.dispose();
        await service.archive.close();
      });
      service.ingestPayload(testPayload('a'));
      service.ingestPayload(testPayload('b'));
      final color = service.layers['a']!.color;
      expect(service.layers['b']!.color, isNot(color));
      service.layers.setVisible('a', false);
      for (var second = 1; second < 5; second++) {
        service.ingestPayload(
          testPayload('a', second: second, status: second.isEven ? 1 : 4),
        );
      }
      expect(service.tracks['a']!.length, 3);
      expect(service.tracks['b']!.length, 1);
      expect(service.layers['a']!.color, color);
      expect(service.layers.isVisible('a'), isFalse);
      expect(
        service.ingestPayload(testPayload('a', second: 4, status: 1)),
        isFalse,
      );
      expect(
        service.ingestPayload(
          testPayload('a', second: 5, time: '2026-01-08T10:00:00Z'),
        ),
        isFalse,
      );
      service.clearTracks();
      service.ingestPayload(testPayload('a', second: 6));
      expect(service.layers['a']!.color, color);
      expect(service.layers.isVisible('a'), isFalse);
      expect(service.tracks['a']!.length, 1);
    },
  );

  test('reusable layers batch-toggle and preserve identity', () {
    final layers = MapLayerController();
    addTearDown(layers.dispose);
    for (var i = 0; i < 16; i++) {
      layers.ensureLayer('$i');
    }
    expect(layers.layers.map((e) => e.color).toSet().length, 16);
    layers.setAllVisible(false);
    expect(layers.layers.every((e) => !e.visible), isTrue);
    layers.ensureLayer('0');
    expect(layers.isVisible('0'), isFalse);
    layers.setAllVisible(true);
    expect(layers.layers.every((e) => e.visible), isTrue);
  });

  test(
    'global cache and device metadata remain bounded while disk keeps all fixes',
    () async {
      final service = MqttPositionService(
        maxPointsPerDevice: 5,
        maxTotalPoints: 6,
        maxDevices: 3,
        archive: testArchive(),
      );
      addTearDown(() async {
        service.dispose();
        await service.archive.close();
      });
      for (var i = 0; i < 200; i++) {
        service.ingestPayload(testPayload('device_${i % 5}', second: i % 60));
        expect(service.cachedPoints, lessThanOrEqualTo(6));
        expect(service.tracks.length, lessThanOrEqualTo(3));
        expect(service.layers.layers.length, lessThanOrEqualTo(3));
      }
      await service.archive.flush();
      final files = await service.archive.recentFiles();
      final records = await files.single.readAsLines();
      expect(records, hasLength(200));
      expect(service.evictedPoints, greaterThan(0));
      expect(service.evictedDevices, greaterThan(0));
      expect(jsonDecode(records.first)['received_at'], isNotNull);
      expect(MqttPositionFix.parse(records.first), isNotNull);
      service.clearTracks();
      expect(service.cachedPoints, 0);
      expect(await files.single.readAsLines(), hasLength(200));
    },
  );

  test(
    'global point cap also bounds a few continuously active hidden devices',
    () async {
      final service = MqttPositionService(
        maxPointsPerDevice: 20,
        maxTotalPoints: 6,
        archive: testArchive(),
      );
      addTearDown(() async {
        service.dispose();
        await service.archive.close();
      });
      for (var second = 0; second < 30; second++) {
        for (final id in ['a', 'b']) {
          service.ingestPayload(testPayload(id, second: second));
        }
        service.layers.setAllVisible(false);
        expect(service.cachedPoints, lessThanOrEqualTo(6));
        expect(
          service.tracks.values.fold(0, (sum, t) => sum + t.length),
          service.cachedPoints,
        );
      }
      expect(service.cachedPoints, 6);
      expect(service.evictedPoints, 54);
      await service.archive.flush();
      expect(service.archive.savedRecords, 60);
    },
  );

  test(
    'archive appends across restart and rolls over by UTC reception date',
    () async {
      final archive = testArchive();
      archive.record({'gga': 'first'}, DateTime.utc(2026, 9, 23, 23, 59));
      archive.record({'gga': 'second'}, DateTime.utc(2026, 9, 24));
      await archive.close();
      final reopened = testArchive();
      reopened.record({'gga': 'third'}, DateTime.utc(2026, 9, 24, 1));
      await reopened.close();
      expect(
        await File('${archiveDirectory.path}/MQTT20260923.jsonl').readAsLines(),
        hasLength(1),
      );
      final records = await File(
        '${archiveDirectory.path}/MQTT20260924.jsonl',
      ).readAsLines();
      expect(records.map((line) => jsonDecode(line)['gga']), [
        'second',
        'third',
      ]);
    },
  );

  test(
    'slow disk has a bounded write queue and reports unsaved records',
    () async {
      final gate = Completer<Directory>();
      final archive = MqttPositionArchive(
        directory: () => gate.future,
        maxPendingRecords: 3,
      );
      for (var i = 0; i < 10; i++) {
        archive.record({'i': i}, DateTime.utc(2026, 9, 24));
      }
      expect(archive.pendingRecords, 3);
      expect(archive.droppedRecords, 7);
      expect(archive.error, contains('未能保存'));
      gate.complete(archiveDirectory);
      await archive.close();
      expect(archive.pendingRecords, 0);
      expect(archive.savedRecords, 3);
    },
  );

  test(
    'disk errors keep pending records for retry without corrupting the log',
    () async {
      var fail = true;
      final archive = MqttPositionArchive(
        directory: () async {
          if (fail) throw const FileSystemException('test disk failure');
          return archiveDirectory;
        },
      );
      archive.record({'i': 1}, DateTime.utc(2026, 9, 24));
      await archive.flush();
      expect(archive.error, isNotNull);
      expect(archive.pendingRecords, 1);
      fail = false;
      await archive.flush();
      expect(archive.error, isNull);
      expect(archive.savedRecords, 1);
      await archive.close();
    },
  );

  test(
    'real MQTT socket subscribes, receives JSON and resubscribes after loss',
    () async {
      final broker = await _TestBroker.start();
      final service = MqttPositionService(archive: testArchive());
      addTearDown(() async {
        service.dispose();
        await broker.close();
      });
      await service.connect(
        MqttPositionSettings(
          host: '127.0.0.1',
          port: broker.port,
          topic: 'app',
        ),
      );
      await waitUntil(
        () => service.connection == MqttPositionConnection.connected,
      );
      expect(broker.topics, ['app']);
      broker.publish(testPayload('a'));
      broker.publish(testPayload('b'));
      await waitUntil(() => service.tracks.length == 2);
      broker.sockets.last.destroy();
      await waitUntil(
        () =>
            broker.topics.length == 2 &&
            service.connection == MqttPositionConnection.connected,
      );
      broker.publish(testPayload('a', second: 1));
      await waitUntil(() => service.tracks['a']!.length == 2);
      service.disconnect();
      expect(service.connection, MqttPositionConnection.disconnected);
      expect(service.tracks.length, 2);
    },
  );

  test(
    'subscription rejection is visible and releases the connection',
    () async {
      final broker = await _TestBroker.start(rejectSubscription: true);
      final service = MqttPositionService(archive: testArchive());
      addTearDown(() async {
        service.dispose();
        await broker.close();
      });
      await service.connect(
        MqttPositionSettings(host: '127.0.0.1', port: broker.port),
      );
      await waitUntil(
        () => service.connection == MqttPositionConnection.failed,
      );
      expect(service.error, contains('拒绝订阅'));
      expect(service.isActive, isFalse);
    },
  );
}

/// Minimal local MQTT 3.1.1 broker: exercises the actual client socket/protocol.
class _TestBroker {
  _TestBroker(this.server, this.rejectSubscription) {
    server.listen((socket) {
      sockets.add(socket);
      final buffer = <int>[];
      socket.listen((data) {
        buffer.addAll(data);
        while (buffer.length >= 2) {
          var remaining = 0, multiplier = 1, offset = 1;
          int digit;
          do {
            if (offset >= buffer.length) return;
            digit = buffer[offset++];
            remaining += (digit & 127) * multiplier;
            multiplier *= 128;
          } while (digit & 128 != 0);
          if (buffer.length < offset + remaining) return;
          final type = buffer[0] >> 4;
          final body = buffer.sublist(offset, offset + remaining);
          buffer.removeRange(0, offset + remaining);
          if (type == 1) socket.add([0x20, 2, 0, 0]);
          if (type == 8) {
            final length = body[2] * 256 + body[3];
            topics.add(utf8.decode(body.sublist(4, 4 + length)));
            socket.add([
              0x90,
              3,
              body[0],
              body[1],
              rejectSubscription ? 0x80 : 0,
            ]);
          }
          if (type == 12) socket.add([0xD0, 0]);
          if (type == 14) socket.destroy();
        }
      }, onError: (_) {});
    });
  }
  final ServerSocket server;
  final bool rejectSubscription;
  final sockets = <Socket>[];
  final topics = <String>[];
  int get port => server.port;
  static Future<_TestBroker> start({bool rejectSubscription = false}) async =>
      _TestBroker(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        rejectSubscription,
      );
  void publish(String payload) {
    final body = [0, 3, ...utf8.encode('app'), ...utf8.encode(payload)];
    var length = body.length;
    final header = <int>[0x30];
    do {
      var digit = length % 128;
      length ~/= 128;
      if (length > 0) digit |= 128;
      header.add(digit);
    } while (length > 0);
    sockets.last.add([...header, ...body]);
  }

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  }
}
