import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/app_ui.dart';
import 'package:rtkmanager/device_connection_page.dart';
import 'package:rtkmanager/gnss_ble_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/filtered_ble');
  late StreamController<dynamic> events;
  late GnssBleService service;
  late List<MethodCall> calls;

  setUp(() {
    events = StreamController<dynamic>.broadcast(sync: true);
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    service = GnssBleService(methods: channel, events: events.stream);
    for (var i = 0; i < 30; i++) {
      events.add({
        'type': 'device',
        'id': 'AA:BB:CC:DD:EE:${i.toString().padLeft(2, '0')}',
        'name': '未命名设备',
        'rssi': -50,
      });
    }
    events.add({
      'type': 'device',
      'id': '11:22:33:44:55:66',
      'name': 'BlueNRG Rover',
      'rssi': -85,
    });
  });

  tearDown(() async {
    service.dispose();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final (size, scale) in [
    (const Size(375, 812), 1.0),
    (const Size(320, 640), 2.0),
    (const Size(812, 375), 2.0),
  ]) {
    testWidgets(
      'BLE filters remain usable at $size / $scale and connect the chosen result',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            theme: mobileTheme(ThemeData()),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: DeviceConnectionPage(
              service: service,
              onOpenDrawer: () {},
              onShowPositioning: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scrollable = find.byType(Scrollable).first;
        Future<void> reveal(Finder finder) async {
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await tester.pump();
          await tester.scrollUntilVisible(finder, 220, scrollable: scrollable);
          await tester.pumpAndSettle();
          final error = tester.takeException();
          if (error is FlutterError) {
            fail(
              error.diagnostics.map((node) => node.toStringDeep()).join('\n'),
            );
          }
          expect(error, isNull);
        }

        final field = find.byType(TextField);
        await reveal(find.text('1 / 31 台'));
        expect(find.text('1 / 31 台'), findsOneWidget);
        expect(service.filteredDevices().single.name, 'BlueNRG Rover');

        final toggle = find.widgetWithText(FilterChip, '显示未命名设备');
        await reveal(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        await reveal(find.text('31 / 31 台'));
        expect(find.text('31 / 31 台'), findsOneWidget);
        await reveal(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();

        await reveal(field);
        await tester.enterText(field, 'aabbccddee07');
        await tester.pumpAndSettle();
        final unnamed = find.byKey(
          const ValueKey('ble-device-AA:BB:CC:DD:EE:07'),
        );
        await reveal(unnamed);
        expect(unnamed, findsOneWidget);
        expect(find.text('未命名设备'), findsOneWidget);
        expect(find.text('没有匹配的设备'), findsNothing);

        await reveal(field);
        await tester.enterText(field, 'missing');
        await tester.pumpAndSettle();
        await reveal(find.text('没有匹配的设备'));
        expect(find.text('没有匹配的设备'), findsOneWidget);
        await reveal(field);
        await tester.tap(find.byTooltip('清除搜索'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, isEmpty);
        await tester.enterText(field, 'rOvEr');
        await tester.pumpAndSettle();
        events.add({
          'type': 'device',
          'id': '11:22:33:44:55:66',
          'name': '未命名设备',
          'rssi': -90,
        });
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(field).controller!.text, 'rOvEr');
        final receiver = find.byKey(
          const ValueKey('ble-device-11:22:33:44:55:66'),
        );
        await reveal(receiver);
        expect(find.text('BlueNRG Rover'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(receiver);
        await tester.pumpAndSettle();
        expect(
          calls.where((call) => call.method == 'connect').single.arguments,
          {'id': '11:22:33:44:55:66'},
        );
        expect(service.connection, GnssBleConnection.connecting);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
