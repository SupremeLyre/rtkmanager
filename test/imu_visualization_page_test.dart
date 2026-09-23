import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/imu_visualization_page.dart';
import 'package:rtkmanager/mobile_ui.dart';

ImuData wave(int i) => ImuData()
  ..gpsWeek = 2400
  ..gpsTowNanos = i * 10000000
  ..ax = sin(i / 20) * .2
  ..ay = cos(i / 30) * .1
  ..az = 1 + sin(i / 12) * .03
  ..wx = sin(i / 25) * 20
  ..wy = cos(i / 40) * 12
  ..wz = sin(i / 17) * 8
  ..mx = 10 + sin(i / 60) * 4
  ..my = -20 + cos(i / 50) * 3
  ..mz = 35 + sin(i / 42) * 2;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'SourceCodePro',
    )..addFont(rootBundle.load('fonts/SourceCodePro-Regular.ttf'))).load();
    await (FontLoader(
      'SourceHanSansHWSC',
    )..addFont(rootBundle.load('fonts/SourceHanSansHWSC-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final (size, scale, platform, dark) in [
    (const Size(375, 812), 1.0, TargetPlatform.android, false),
    (const Size(812, 375), 2.0, TargetPlatform.android, false),
    (const Size(320, 640), 2.0, TargetPlatform.android, true),
    (const Size(1400, 820), 1.0, TargetPlatform.windows, false),
  ]) {
    testWidgets('live IMU controls and plots at $size / $scale / $dark', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final stream = StreamController<ImuData>.broadcast();
      final boundary = GlobalKey();
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: dark ? Brightness.dark : Brightness.light,
        ),
        platform: platform,
        fontFamily: 'SourceHanSansHWSC',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: platform == TargetPlatform.android
              ? mobileTheme(theme)
              : theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: boundary,
            child: ImuVisualizationPage(
              dataStream: stream.stream,
              sourceLabel: platform == TargetPlatform.android
                  ? '手机传感器'
                  : '串口 · COM3',
              emptyMessage: '等待采集或串口连接',
              onOpenDrawer: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('已接收 0 帧'), findsOneWidget);
      for (var i = 0; i < 1000; i++) {
        stream.add(wave(i));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.textContaining('已接收 1000 帧'), findsOneWidget);
      expect(find.text('等待 IMU 数据'), findsNothing);
      expect(tester.takeException(), isNull);
      if (scale == 1) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          Directory('build/ui-previews').createSync(recursive: true);
          File(
            'build/ui-previews/imu-${platform.name}.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
          image.dispose();
        });
      }
      final pause = find.widgetWithText(OutlinedButton, '暂停显示');
      await tester.ensureVisible(pause);
      await tester.tap(pause);
      await tester.pump();
      stream.add(wave(1000));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('已接收 1000 帧'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '继续显示'));
      await tester.pump();
      expect(find.textContaining('已接收 1001 帧'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('磁场 · µT'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final clear = find.widgetWithText(OutlinedButton, '清除曲线');
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pump();
      await tester.ensureVisible(clear);
      await tester.pump();
      await tester.tap(clear);
      await tester.pump();
      expect(find.textContaining('已接收 0 帧'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await stream.close();
    });
  }
}
