import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/android_app_frame.dart';
import 'package:rtkmanager/device_connection_page.dart';
import 'package:rtkmanager/gga_log_page.dart';
import 'package:rtkmanager/gga_log_service.dart';
import 'package:rtkmanager/gnss_ble_service.dart';
import 'package:rtkmanager/imu_batch_decode_page.dart';
import 'package:rtkmanager/mobile_ui.dart';
import 'package:rtkmanager/phone_capture_page.dart';
import 'package:rtkmanager/phone_capture_service.dart';

class _Capture extends PhoneCaptureService {
  @override
  void listen() {}
}

class _Logs extends GgaLogService {
  _Logs()
    : super(
        messages: const Stream.empty(),
        directory: () async => Directory('build/ui-preview-logs'),
      );
  @override
  Future<List<GgaLogFile>> listFiles() async => [
    GgaLogFile(
      name: 'GGA20260919.txt',
      modified: DateTime.utc(2026, 9, 19, 9, 42),
    ),
    GgaLogFile(
      name: 'GGA20260918.txt',
      modified: DateTime.utc(2026, 9, 18, 16, 30),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'SourceHanSansHWSC',
    )..addFont(rootBundle.load('fonts/SourceHanSansHWSC-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final (size, scale) in [
    (const Size(375, 812), 1.0),
    (const Size(812, 375), 2.0),
    (const Size(768, 1024), 1.0),
  ]) {
    testWidgets(
      'Android tools render and scroll at $size / $scale with reduced motion',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          PhoneCaptureService.channel,
          (call) async => call.method == 'sessions' ? [] : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            PhoneCaptureService.channel,
            null,
          ),
        );
        final bluetooth = GnssBleService(events: const Stream.empty());
        final capture = _Capture()
          ..state = {
            'mode': 'probing',
            'timeReady': true,
            'sensors': {
              for (final key in ['gnss', 'accel', 'gyro', 'mag'])
                key: {'available': true, 'detail': '可用 · 已检测到传感器'},
            },
          };
        late _Logs logs;
        await tester.runAsync(() async {
          logs = _Logs();
          await logs.ready;
        });
        addTearDown(bluetooth.dispose);
        addTearDown(capture.dispose);
        addTearDown(logs.dispose);

        for (final (name, page) in <(String, Widget)>[
          (
            'device',
            DeviceConnectionPage(
              service: bluetooth,
              onOpenDrawer: () {},
              onShowPositioning: () {},
            ),
          ),
          ('capture', PhoneCapturePage(service: capture, onOpenDrawer: () {})),
          (
            'logs',
            GgaLogPage(service: logs, onOpenDrawer: () {}, active: true),
          ),
          ('decode', ImuBatchDecodePage(onOpenDrawer: () {})),
        ]) {
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: mobileTheme(
                ThemeData(
                  platform: TargetPlatform.android,
                  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
                  fontFamily: 'SourceHanSansHWSC',
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  disableAnimations: true,
                  padding: const EdgeInsets.only(top: 24, bottom: 24),
                ),
                child: RepaintBoundary(
                  key: boundary,
                  child: AndroidAppFrame(child: child!),
                ),
              ),
              home: page,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$name first screen');
          expect(find.byTooltip('打开导航').hitTestable(), findsOneWidget);
          if (size.width == 375) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final output = File('build/ui-previews/$name.png');
              await output.parent.create(recursive: true);
              await output.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          // Check all sections, including chips, paths and empty states below the fold.
          for (var i = 0; i < 10; i++) {
            await tester.drag(
              find.byType(Scrollable).first,
              const Offset(0, -350),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull, reason: '$name scroll $i');
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }
      },
    );
  }
}
