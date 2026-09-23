import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/app_ui.dart';
import 'package:rtkmanager/imu_batch_decode_page.dart';
import 'package:rtkmanager/imu_visualization_page.dart';
import 'package:rtkmanager/rtk_config_page.dart';
import 'package:rtkmanager/satellite_page.dart';
import 'package:rtkmanager/satellite_info.dart';
import 'package:rtkmanager/serial_debug_page.dart';

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

  for (final (size, scale, brightness) in [
    (const Size(375, 812), 1.0, Brightness.light),
    (const Size(812, 375), 2.0, Brightness.light),
    (const Size(1000, 760), 1.0, Brightness.light),
    (const Size(1440, 900), 1.0, Brightness.dark),
  ]) {
    testWidgets('Shared tools adapt at $size / $scale / $brightness', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final (name, page) in <(String, Widget)>[
        ('serial', SerialDebugPage(onOpenDrawer: () {})),
        ('rtk', RtkConfigPage(onOpenDrawer: () {}, listSerialPorts: () => [])),
        ('satellites', SatellitePage(onOpenDrawer: () {})),
        ('decode', ImuBatchDecodePage(onOpenDrawer: () {})),
        (
          'imu',
          ImuVisualizationPage(
            dataStream: const Stream.empty(),
            sourceLabel: '串口 · 等待连接',
            emptyMessage: '连接串口后查看 IMU 实时数据。',
            onOpenDrawer: () {},
          ),
        ),
      ]) {
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: mobileTheme(
              ThemeData(
                platform: TargetPlatform.windows,
                colorScheme: ColorScheme.fromSeed(
                  seedColor: Colors.blue,
                  brightness: brightness,
                ),
                fontFamily: 'SourceHanSansHWSC',
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: RepaintBoundary(key: boundary, child: child!),
            ),
            home: page,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$name first screen');
        expect(find.byTooltip('打开导航').hitTestable(), findsOneWidget);
        if (name == 'satellites') {
          expect(find.text('等待卫星信号'), findsOneWidget);
          SatelliteService().processGsvSentence(
            r'$GPGSV,1,1,03,01,45,049,47,02,17,308,41,03,04,224,25*00',
          );
          await tester.pumpAndSettle();
          expect(find.text('等待卫星信号'), findsNothing);
          expect(find.text('GPS (3)'), findsOneWidget);
          expect(
            tester.takeException(),
            isNull,
            reason: 'satellite data charts',
          );
        }
        if (size.width >= 1000) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/shared-$name-${brightness.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        for (var i = 0; i < 5; i++) {
          final scrollables = find.byType(Scrollable);
          if (scrollables.evaluate().isEmpty) break;
          await tester.drag(
            name == 'serial' ? scrollables.last : scrollables.first,
            const Offset(0, -300),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$name scroll $i');
        }
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    });
  }

  testWidgets(
    'Decode choices survive switching between stacked and column layouts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: mobileTheme(ThemeData()),
          home: ImuBatchDecodePage(onOpenDrawer: () {}),
        ),
      );
      final magnetic = find.widgetWithText(FilterChip, '输出磁场 (µT)');
      await tester.ensureVisible(magnetic);
      await tester.tap(magnetic);
      await tester.pump();
      expect(tester.widget<FilterChip>(magnetic).selected, isTrue);
      for (final size in [const Size(375, 812), const Size(1100, 900)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(tester.widget<FilterChip>(magnetic).selected, isTrue);
        await tester.ensureVisible(find.text('选择输出目录'));
        await tester.pumpAndSettle();
        expect(find.text('选择输出目录').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
