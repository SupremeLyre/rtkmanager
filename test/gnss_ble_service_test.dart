import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/gnss_ble_service.dart';

const ggaBody =
    'GPGGA,123519.00,3031.7071,N,11421.4181,E,6,18,0.8,35.2,M,0,M,1.0,0000';

String nmea(String body) {
  final checksum = body.codeUnits.fold(0, (value, byte) => value ^ byte);
  return '\$$body*${checksum.toRadixString(16).toUpperCase().padLeft(2, '0')}\r\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('ESP32 GNSS notification protocol', () {
    test('accepts complete GGA with and without a checksum, ignores RMC', () {
      expect(decodeGnssNotification(ascii.encode(nmea(ggaBody))), [
        nmea(ggaBody).trim(),
      ]);
      expect(decodeGnssNotification(ascii.encode('\$$ggaBody\r\n')), [
        '\$$ggaBody',
      ]);
      expect(
        decodeGnssNotification(
          ascii.encode(
            nmea('GNRMC,123519.00,A,3031.7071,N,11421.4181,E,0,0,180926,,,A'),
          ),
        ),
        isEmpty,
      );
    });

    test(
      'rejects corruption, incomplete notifications and malformed fields',
      () {
        final valid = nmea(ggaBody);
        for (final bytes in [
          ascii.encode(valid.replaceFirst('35.2', '36.2')),
          ascii.encode(valid.trim()),
          ascii.encode('\$GPGGA,incomplete\r\n'),
          ascii.encode('\$$ggaBody*X1\r\n'),
          [...ascii.encode(valid), 255],
          ascii.encode('\$$ggaBody${'0' * 256}\r\n'),
        ]) {
          expect(decodeGnssNotification(bytes), isEmpty);
        }
      },
    );

    test('accepts a full 256-byte checksum-free firmware sentence', () {
      final body = '\$$ggaBody'.padRight(254, '0');
      expect(decodeGnssNotification(ascii.encode('$body\r\n')), [body]);
    });
  });

  group('BLE connection and reception', () {
    const channel = MethodChannel('test/gnss_ble');
    const device = GnssBleDevice(
      id: '01:02:03:04:05:06',
      name: 'BlueNRG',
      rssi: -50,
    );
    late StreamController<dynamic> events;
    late GnssBleService service;
    late List<MethodCall> calls;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      events = StreamController<dynamic>.broadcast(sync: true);
      calls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      service = GnssBleService(methods: channel, events: events.stream);
    });
    tearDown(() async {
      service.dispose();
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });

    void state(String value, {String? message}) => events.add({
      'type': 'state',
      'state': value,
      'message': message,
      'mtu': 259,
    });
    void data(String value) =>
        events.add({'type': 'data', 'bytes': ascii.encode(value)});

    test(
      'keeps discovery order as signals change and clears on a new scan',
      () async {
        await service.startScan();
        events.add({'type': 'scanning', 'value': true});
        for (final (id, rssi) in [
          ('a', -70),
          ('b', -30),
          ('a', -20),
          ('c', -10),
          ('b', -90),
        ]) {
          events.add({
            'type': 'device',
            'id': id,
            'name': 'BlueNRG',
            'rssi': rssi,
          });
        }
        expect(service.scanning, isTrue);
        expect(service.devices.map((device) => device.id), ['a', 'b', 'c']);
        expect(service.devices.map((device) => device.rssi), [-20, -90, -10]);
        await service.stopScan();
        await service.startScan();
        expect(service.devices, isEmpty);
      },
    );

    test('lists all scan results regardless of advertised UUID or name', () {
      for (final (id, name, services) in [
        ('no-services', 'GNSS Rover', null),
        ('empty-services', '未命名设备', <String>[]),
        (
          'other-service',
          'Heart rate monitor',
          ['0000180d-0000-1000-8000-00805f9b34fb'],
        ),
        ('gnss-service', 'BlueNRG', ['00000000-0001-11e1-9ab4-0002a5d5c51b']),
      ]) {
        events.add({
          'type': 'device',
          'id': id,
          'name': name,
          'rssi': -20,
          'serviceUuids': services,
        });
      }
      expect(
        service.devices.map((device) => device.id),
        unorderedEquals([
          'no-services',
          'empty-services',
          'other-service',
          'gnss-service',
        ]),
      );
      expect(service.devices.map((device) => device.name), contains('未命名设备'));
    });

    test('permission denial is shown and permits retry', () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'permission', message: '需要蓝牙权限');
      });
      await service.startScan();
      expect(service.error, '需要蓝牙权限');
      expect(service.requestingScan, isFalse);
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      await service.startScan();
      expect(service.error, isNull);
    });

    test(
      'default filter keeps named receivers, search also finds unnamed addresses',
      () {
        for (final (id, name) in [
          ('AA:BB:CC:00:00:01', '  Survey Rover  '),
          ('AA:BB:CC:00:00:02', '未命名设备'),
          ('AA:BB:CC:00:00:03', '   '),
          ('AA:BB:CC:00:00:04', 'Custom Receiver'),
        ]) {
          events.add({'type': 'device', 'id': id, 'name': name, 'rssi': -95});
        }
        expect(service.filteredDevices().map((device) => device.name), [
          'Survey Rover',
          'Custom Receiver',
        ]);
        expect(service.filteredDevices(includeUnnamed: true), hasLength(4));
        expect(
          service.filteredDevices(query: '  survey ROV  ').single.id,
          'AA:BB:CC:00:00:01',
        );
        expect(
          service.filteredDevices(query: 'aabbcc000002').single.name,
          '未命名设备',
        );
        expect(
          service.filteredDevices(query: 'AA-BB-CC-00-00-03').single.name,
          '未命名设备',
        );
        expect(service.filteredDevices(query: 'missing'), isEmpty);
        expect(service.filteredDevices(query: ' : - '), isEmpty);
        expect(service.filteredDevices(query: '  '), hasLength(2));
        expect(
          service.devices,
          hasLength(4),
          reason: 'Filtering never discards raw discoveries',
        );
      },
    );

    test(
      'missing names in later advertisements do not hide a known receiver',
      () async {
        void advertise(String name, int rssi) => events.add({
          'type': 'device',
          'id': 'receiver',
          'name': name,
          'rssi': rssi,
        });
        advertise('未命名设备', -60);
        expect(service.filteredDevices(), isEmpty);
        advertise('BlueNRG', -55);
        expect(service.filteredDevices().single.name, 'BlueNRG');
        advertise('未命名设备', -65);
        advertise('', -70);
        expect(service.filteredDevices().single.name, 'BlueNRG');
        expect(service.filteredDevices().single.rssi, -70);
        advertise('Renamed Receiver', -50);
        expect(service.filteredDevices().single.name, 'Renamed Receiver');
        await service.startScan();
        advertise('未命名设备', -80);
        expect(
          service.filteredDevices(),
          isEmpty,
          reason: 'Name retention only lasts for this scan',
        );
      },
    );

    test(
      'subscribed GGA only, disconnect stops reception and reconnect resets counts',
      () async {
        final received = <String>[];
        final subscription = service.ggaStream.listen(received.add);
        await service.connect(device);
        expect(calls.map((call) => call.method), ['stopScan', 'connect']);
        expect(calls.last.arguments, {'id': device.id});
        data(nmea(ggaBody));
        expect(received, isEmpty);
        state('mtu');
        expect(service.connection, GnssBleConnection.connecting);
        state('connected');
        data(nmea('GNRMC,123519.00,A,,,,,,,,,,,'));
        data(nmea(ggaBody));
        data('\$$ggaBody\r\n');
        expect(received.length, 2);
        expect(service.ggaCount, 2);
        expect(service.latestGga, '\$$ggaBody');
        expect(service.lastReceived, isNotNull);
        state('disconnected', message: '设备已断开');
        data(nmea(ggaBody));
        expect(received.length, 2);
        expect(service.error, '设备已断开');
        await service.connect(device);
        expect(service.ggaCount, 0);
        expect(service.error, isNull);
        expect(service.latestGga, isNull);
        state('connected');
        data(nmea(ggaBody));
        expect(service.ggaCount, 1);
        await subscription.cancel();
      },
    );

    test('rapid taps cannot open two simultaneous connections', () async {
      await Future.wait([service.connect(device), service.connect(device)]);
      expect(calls.where((call) => call.method == 'connect').length, 1);
    });

    test(
      'GATT validation failure disconnects without accepting GGA and permits retry',
      () async {
        await service.connect(device);
        state('discovering');
        data(nmea(ggaBody));
        expect(service.ggaCount, 0);
        state('disconnected', message: '设备的 GNSS 服务与当前固件协议不匹配，请核对 ESP32 固件');
        data(nmea(ggaBody));
        expect(service.isActive, isFalse);
        expect(service.error, contains('不匹配'));
        expect(service.ggaCount, 0);
        await service.connect(device);
        state('connected');
        data(nmea(ggaBody));
        expect(service.error, isNull);
        expect(service.ggaCount, 1);
      },
    );

    test(
      'cancelled scan awaiting permissions cannot report a stale error',
      () async {
        final pending = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'startScan') await pending.future;
          return null;
        });
        final scan = service.startScan();
        await service.stopScan();
        pending.completeError(
          PlatformException(code: 'scan', message: '扫描已取消'),
        );
        await scan;
        expect(service.error, isNull);
        expect(service.requestingScan, isFalse);
      },
    );

    test(
      'cancelling a pending connect prevents a late connect command',
      () async {
        final pending = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'stopScan') await pending.future;
          return null;
        });
        final connecting = service.connect(device);
        await service.disconnect();
        pending.complete();
        await connecting;
        expect(calls.where((call) => call.method == 'connect'), isEmpty);
        expect(service.isActive, isFalse);
      },
    );

    test(
      'native connection failure leaves controls available for retry',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'connect') {
            throw PlatformException(code: 'bluetooth', message: '设备不匹配');
          }
          return null;
        });
        await service.connect(device);
        expect(service.connection, GnssBleConnection.disconnected);
        expect(service.error, '设备不匹配');
      },
    );
  });
}
