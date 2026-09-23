import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/phone_capture_page.dart';
import 'package:rtkmanager/phone_capture_service.dart';

class FakeCapture extends PhoneCaptureService {
  final commands = <(String, Map<String, dynamic>?)>[];
  @override
  void listen() {}
  @override
  Future<void> command(String method, [Map<String, dynamic>? args]) async {
    commands.add((method, args));
  }

  void update({
    required bool synced,
    bool available = true,
    bool recording = false,
    bool gyro = false,
  }) {
    state = {
      'mode': recording ? 'recording' : 'probing',
      'timeReady': synced,
      'sensors': {
        'gnss': {'available': available},
        'accel': {'available': available},
        'gyro': {'available': gyro, 'detail': gyro ? '已收到数据' : '未发现对应硬件'},
        'mag': {'available': available},
      },
    };
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          PhoneCaptureService.channel,
          (call) async => call.method == 'sessions' ? [] : null,
        ),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PhoneCaptureService.channel, null),
  );

  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets(
      'sensor availability and clock gate capture at $size / 2x text',
      (tester) async {
        final service = FakeCapture();
        addTearDown(service.dispose);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: PhoneCapturePage(service: service, onOpenDrawer: () {}),
          ),
        );
        await tester.pumpAndSettle();
        Finder option(String text) =>
            find.widgetWithText(CheckboxListTile, text);
        Finder start() =>
            find.byWidgetPredicate((widget) => widget is FilledButton);
        Future<void> show(Finder finder, {bool up = false}) async {
          await tester.scrollUntilVisible(
            finder,
            up ? -220 : 220,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
        }

        await show(start());
        expect(tester.widget<FilledButton>(start()).onPressed, isNull);
        await show(option('磁传感器'));
        expect(
          tester.widget<CheckboxListTile>(option('磁传感器')).onChanged,
          isNull,
        );
        service.update(synced: false);
        await tester.pump();
        await show(option('IMU（加速度计 + 陀螺仪）'), up: true);
        expect(
          tester.widget<CheckboxListTile>(option('IMU（加速度计 + 陀螺仪）')).onChanged,
          isNull,
        );
        await show(option('磁传感器'));
        await tester.tap(option('磁传感器'));
        await tester.pump();
        await show(start(), up: true);
        expect(tester.widget<FilledButton>(start()).onPressed, isNull);
        service.update(synced: true);
        await tester.pump();
        await tester.ensureVisible(start());
        await tester.tap(start());
        await tester.pump();
        expect(service.commands.single.$1, 'start');
        expect(service.commands.single.$2?['sensors'], ['mag']);
        expect(service.commands.single.$2?['imuHz'], 100);
        expect(service.commands.single.$2?['magHz'], 50);
        service.update(synced: true, available: false);
        await tester.pump();
        expect(tester.widget<FilledButton>(start()).onPressed, isNull);
        service.update(synced: true, recording: true);
        await tester.pump();
        await show(option('磁传感器'));
        expect(
          tester.widget<CheckboxListTile>(option('磁传感器')).onChanged,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'selects six-axis IMU as one item and requests independent rates',
    (tester) async {
      final service = FakeCapture()..update(synced: true, gyro: true);
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneCapturePage(service: service, onOpenDrawer: () {}),
        ),
      );
      await tester.pumpAndSettle();
      final imu = find.widgetWithText(CheckboxListTile, 'IMU（加速度计 + 陀螺仪）');
      await tester.scrollUntilVisible(
        imu,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(imu);
      await tester.pump();
      final magRate = find.byKey(const ValueKey('mag-rate'));
      await tester.scrollUntilVisible(
        magRate,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      tester.widget<DropdownButtonFormField<int>>(magRate).onChanged!(25);
      final imuRate = find.byKey(const ValueKey('imu-rate'));
      tester.widget<DropdownButtonFormField<int>>(imuRate).onChanged!(200);
      await tester.pump();
      final start = find.widgetWithText(FilledButton, '开始采集');
      await tester.scrollUntilVisible(
        start,
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(start);
      await tester.pump();
      expect(service.commands.single.$2, {
        'sensors': ['imu'],
        'imuHz': 200,
        'magHz': 25,
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('native permission error remains actionable', () async {
    final service = PhoneCaptureService();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          PhoneCaptureService.channel,
          (call) async =>
              throw PlatformException(code: 'permission', message: '需要精确位置权限'),
        );
    await service.command('probe');
    expect(service.error, '需要精确位置权限');
    expect(service.busy, false);
    service.dispose();
  });
}
