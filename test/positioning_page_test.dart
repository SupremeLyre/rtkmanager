import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:rtkmanager/trajectory_layer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/android_home_page.dart';
import 'package:rtkmanager/android_app_frame.dart';
import 'package:rtkmanager/app_ui.dart';
import 'package:rtkmanager/gga_log_service.dart';
import 'package:rtkmanager/gnss_ble_service.dart';
import 'package:rtkmanager/positioning_page.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/mqtt_position_service.dart';
import 'package:rtkmanager/mqtt_position_archive.dart';
import 'mqtt_position_service_test.dart' show testPayload;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File input;
  late Directory tileCacheDirectory;
  late BuiltInMapCachingProvider tileCache;
  final followButton = find.byWidgetPredicate(
    (widget) => widget is IconButton && widget.tooltip == '自动跟随',
  );

  setUpAll(() async {
    tileCacheDirectory = Directory.systemTemp.createTempSync('gga_tiles_test_');
    tileCache = BuiltInMapCachingProvider.getOrCreateInstance(
      cacheDirectory: tileCacheDirectory.path,
      readOnly: true,
      overrideFreshAge: const Duration(days: 1),
    );
    await (FontLoader(
      'SourceHanSansHWSC',
    )..addFont(rootBundle.load('fonts/SourceHanSansHWSC-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  tearDownAll(() async {
    await tileCache.destroy();
    tileCacheDirectory.deleteSync(recursive: true);
  });

  setUp(() {
    directory = Directory.systemTemp.createTempSync('gga_map_test_');
    input = File('${directory.path}/mixed.log')
      ..writeAsStringSync(
        [
          for (final status in [0, 1, 2, 4, 5, 6])
            '\$${status == 2
                ? 'GP'
                : status == 4
                ? 'GB'
                : 'GN'}GGA,12345$status.00,3031.7071,N,11421.4181,E,$status,18,0.8,35.2,M,0,M,1.0,0000*00',
          '\$PPPSOL,20260918123456.00,4,18,114.35,0.01,30.52,0.01,35,0.01,0,0,0,0,0,0,0,0,0,0,1,1,1*00',
          '\$GNRMC,123456.00,A,3031.7071,N,11421.4181,E,0,0,180926,,,A*00',
          '',
        ].join('\r\n'),
      );
    FilePicker.platform = _TestFilePicker(input.path);
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  testWidgets('Desktop PPP keeps its readings in the shared position card', (
    tester,
  ) async {
    input.writeAsStringSync(
      '\$PPPSOL,20260918123456.00,4,18,114.35,0.01,30.52,0.01,35,0.01,0,3,0.03,4,0.04,0,0,0,0,0,1,2,3,0*00\r\n',
    );
    await HttpOverrides.runZoned(() async {
      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: mobileTheme(ThemeData(fontFamily: 'SourceHanSansHWSC')),
          home: MobilePositioningPage(onOpenDrawer: () {}),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('从文件导入IMU定位数据'));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (find.textContaining('文件解析完成').evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      expect(find.text('文件解析完成，共载入 1 个轨迹点'), findsOneWidget);
      final context = tester.element(find.byType(MobilePositioningPage));
      ScaffoldMessenger.of(context).removeCurrentSnackBar();
      await tester.pumpAndSettle();

      for (final size in [const Size(1000, 760), const Size(400, 720)]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(find.text('PPP UTC: 12:34:56.00'), findsOneWidget);
        expect(find.text('18'), findsOneWidget);
        expect(find.text('1.00'), findsOneWidget);
        expect(find.text('35.0 m'), findsOneWidget);
        expect(find.byTooltip('查看定位详情').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('查看定位详情'));
        await tester.pumpAndSettle();
        for (final label in [
          '参与定位的卫星',
          '精度因子 DOP 1',
          '35.00 m',
          '5.000 m/s',
          '0.017 m',
          '0.050 m/s',
          '2.00 / 3.00',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('水平精度因子 HDOP'), findsNothing);
        expect(find.text('差分龄期'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭定位详情'));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, createHttpClient: (_) => _TileHttpClient());
  });

  testWidgets('live IMU visibility and MQTT isolation preserve incoming data', (
    tester,
  ) async {
    await HttpOverrides.runZoned(() async {
      await tester.binding.setSurfaceSize(const Size(1000, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: MobilePositioningPage(onOpenDrawer: () {})),
      );
      await tester.pumpAndSettle();
      void receive(int second) {
        ImuDataParser().parseData(_imuPositionFrame(second), (_) {});
      }

      receive(1);
      await tester.pumpAndSettle();
      expect(_mapPoints(tester), hasLength(1));
      await tester.tap(find.byTooltip('图层管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('layer-visible-imu')));
      await tester.pumpAndSettle();
      receive(2);
      await tester.pumpAndSettle();
      expect(find.text('2 个轨迹点'), findsOneWidget);
      expect(_mapPoints(tester), isEmpty);
      await tester.tap(find.byKey(const ValueKey('layer-visible-imu')));
      await tester.pumpAndSettle();
      expect(_mapPoints(tester), hasLength(2));
      await tester.tap(find.byTooltip('关闭图层管理'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('数据来源'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'MQTT 轨迹'),
      );
      await tester.pumpAndSettle();
      receive(3);
      await tester.pumpAndSettle();
      expect(_mapPoints(tester), isEmpty);
      await tester.tap(find.byTooltip('数据来源'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '串口 / 离线文件'),
      );
      await tester.pumpAndSettle();
      expect(_mapPoints(tester), hasLength(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, createHttpClient: (_) => _TileHttpClient());
  });

  for (final (size, scale) in [
    (const Size(1000, 760), 1.0),
    (const Size(320, 640), 1.0),
    (const Size(320, 640), 2.0),
    (const Size(640, 360), 1.3),
  ]) {
    testWidgets('MQTT device layers and source isolation at $size / $scale', (
      tester,
    ) async {
      final mqtt = MqttPositionService(
        archive: MqttPositionArchive(
          directory: () async => Directory('${directory.path}/MQTT'),
        ),
      );
      addTearDown(() async {
        await tester.runAsync(() async {
          mqtt.dispose();
          await mqtt.archive.close();
        });
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() async {
        for (final id in ['fusion_device_a', 'fusion_device_b']) {
          mqtt.ingestPayload(testPayload(id));
          mqtt.ingestPayload(testPayload(id, second: 1, status: 1));
        }
        await mqtt.archive.flush();
      });
      final previewKey = GlobalKey();
      await HttpOverrides.runZoned(() async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: mobileTheme(
              ThemeData(
                brightness: scale == 2 ? Brightness.dark : Brightness.light,
                colorSchemeSeed: Colors.blue,
                fontFamily: 'SourceHanSansHWSC',
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: previewKey, child: child!),
            ),
            home: MobilePositioningPage(mqtt: mqtt, onOpenDrawer: () {}),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('从文件导入IMU定位数据'));
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (find.textContaining('文件解析完成').evaluate().isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        ScaffoldMessenger.of(
          tester.element(find.byType(MobilePositioningPage)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
        final localCount = _mapPoints(tester).length;
        expect(localCount, 6);
        await tester.tap(find.byTooltip('数据来源'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, 'MQTT 轨迹'),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar,
          isNull,
        );
        expect(find.byType(Slider), findsNothing);
        var lines = tester
            .widget<PolylineLayer>(find.byType(PolylineLayer))
            .polylines;
        expect(lines, hasLength(2));
        expect(lines.first.color, mqtt.layers['fusion_device_a']!.color);
        expect(lines.last.color, mqtt.layers['fusion_device_b']!.color);
        expect(lines.first.color, isNot(lines.last.color));
        expect(_mapPoints(tester), hasLength(6));

        await tester.tap(find.byTooltip('查看定位详情'));
        await tester.pumpAndSettle();
        expect(find.text('设备：fusion_device_a'), findsOneWidget);
        expect(find.text('GGA 原文'), findsOneWidget);
        expect(
          find.text(mqtt.tracks['fusion_device_a']!.latest!.gga),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('关闭定位详情'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('图层管理'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('layer-visible-fusion_device_a')),
        );
        await tester.tap(
          find.byKey(const ValueKey('layer-visible-fusion_device_a')),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          mqtt.ingestPayload(testPayload('fusion_device_a', second: 2));
          await mqtt.archive.flush();
        });
        await tester.pumpAndSettle();
        expect(mqtt.tracks['fusion_device_a']!.length, 3);
        lines = tester
            .widget<PolylineLayer>(find.byType(PolylineLayer))
            .polylines;
        expect(lines, hasLength(1));
        expect(lines.single.color, mqtt.layers['fusion_device_b']!.color);
        await tester.ensureVisible(find.text('全部隐藏'));
        await tester.tap(find.text('全部隐藏'));
        await tester.pumpAndSettle();
        expect(_mapPoints(tester), isEmpty);
        expect(find.byTooltip('查看定位详情'), findsNothing);
        await tester.tap(find.text('全部显示'));
        await tester.pumpAndSettle();
        expect(_mapPoints(tester), hasLength(7));
        if (const bool.fromEnvironment('CAPTURE_UI_PREVIEWS')) {
          await tester.runAsync(() async {
            final boundary =
                previewKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/mqtt-layers-${size.width.toInt()}-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.ensureVisible(find.byTooltip('关闭图层管理'));
        await tester.tap(find.byTooltip('关闭图层管理'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('数据来源'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, '串口 / 离线文件'),
        );
        await tester.pumpAndSettle();
        expect(_mapPoints(tester), hasLength(localCount));
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar,
          isNotNull,
        );
        await tester.tap(find.byTooltip('图层管理'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('layer-visible-gga')),
        );
        await tester.tap(find.byKey(const ValueKey('layer-visible-gga')));
        await tester.pumpAndSettle();
        expect(_mapPoints(tester), hasLength(1));
        await tester.ensureVisible(
          find.byKey(const ValueKey('layer-visible-pppsol')),
        );
        await tester.tap(find.byKey(const ValueKey('layer-visible-pppsol')));
        await tester.pumpAndSettle();
        expect(_mapPoints(tester), isEmpty);
        expect(find.byKey(const ValueKey('layer-visible-imu')), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('关闭图层管理'));
        await tester.tap(find.byTooltip('关闭图层管理'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('数据来源'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('MQTT 连接设置'));
        await tester.pumpAndSettle();
        if (const bool.fromEnvironment('CAPTURE_UI_PREVIEWS')) {
          await tester.runAsync(() async {
            final boundary =
                previewKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/mqtt-receive-${size.width.toInt()}-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.enterText(
          find.byKey(const ValueKey('mqtt-host')),
          'https://invalid',
        );
        await tester.ensureVisible(find.text('连接并接收'));
        await tester.tap(find.text('连接并接收'));
        await tester.pumpAndSettle();
        expect(find.text('请输入域名或 IP，不含协议前缀和路径'), findsOneWidget);
        expect(mqtt.isActive, isFalse);
        await tester.ensureVisible(find.text('接收日志'));
        await tester.runAsync(() async {
          await tester.tap(find.text('接收日志'));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (find.byType(SelectableText).evaluate().isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        expect(find.byTooltip('关闭接收日志'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭接收日志'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('mqtt-host')))
              .controller!
              .text,
          'https://invalid',
        );
        await tester.ensureVisible(find.byTooltip('关闭 MQTT 设置'));
        await tester.tap(find.byTooltip('关闭 MQTT 设置'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('数据来源'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, 'MQTT 轨迹'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('清除轨迹'));
        await tester.pumpAndSettle();
        expect(mqtt.cachedPoints, 0);
        await tester.tap(find.byTooltip('数据来源'));
        await tester.pumpAndSettle();
        final logName = MqttPositionArchive.filenameFor(DateTime.now());
        await tester.runAsync(() async {
          await tester.tap(find.text('MQTT 接收日志'));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (find.byType(SelectableText).evaluate().isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(logName),
          120,
          scrollable: find
              .descendant(
                of: find.byType(ListView).last,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text(logName), findsOneWidget);
        expect(find.text('复制目录路径'), findsOneWidget);
        expect(find.byTooltip('复制文件路径'), findsOneWidget);
        if (const bool.fromEnvironment('CAPTURE_UI_PREVIEWS')) {
          await tester.runAsync(() async {
            final boundary =
                previewKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/mqtt-logs-${size.width.toInt()}-$scale.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }, createHttpClient: (_) => _TileHttpClient());
    });
  }

  for (final (size, scale) in [
    (const Size(320, 640), 1.0),
    (const Size(360, 740), 1.3),
    (const Size(640, 360), 1.0),
    (const Size(320, 640), 2.0),
  ]) {
    testWidgets('GGA controls fit without a legend at $size / $scale', (
      tester,
    ) async {
      input.writeAsStringSync(
        input
            .readAsStringSync()
            .split('\r\n')
            .where((line) => !line.startsWith(r'$PPPSOL'))
            .join('\r\n'),
      );
      await HttpOverrides.runZoned(() async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'SourceHanSansHWSC'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                padding: const EdgeInsets.only(top: 24, bottom: 24),
              ),
              child: AndroidAppFrame(child: child!),
            ),
            home: MobilePositioningPage(
              mobileLayout: true,
              onOpenDrawer: () {},
            ),
          ),
        );
        await tester.pump();

        expect(find.text('定位结果'), findsOneWidget);
        expect(find.text('Fusion'), findsNothing);
        expect(find.text('PPPSOL'), findsNothing);
        expect(find.byTooltip('自动跟随').hitTestable(), findsOneWidget);
        expect(find.byTooltip('打开导航').hitTestable(), findsOneWidget);
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar,
          isNull,
        );
        expect(find.text('SPP (1)'), findsNothing);
        expect(find.text('DR (6)'), findsNothing);
        expect(tester.getRect(find.byType(AppBar)).top, 24);
        expect(
          tester.getRect(find.byType(FlutterMap)).bottom,
          size.height - 24,
        );

        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('导入定位文件'));
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (find.textContaining('文件解析完成').evaluate().isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        expect(find.text('文件解析完成，共载入 5 个轨迹点'), findsOneWidget);
        final markers = _mapPoints(tester);
        expect(markers.length, 5);
        expect(find.text('1 / 5'), findsOneWidget);
        expect(tester.widget<IconButton>(followButton).isSelected, isFalse);

        // Dismiss the completion notice before checking the timeline hit targets.
        final context = tester.element(find.byType(MobilePositioningPage));
        ScaffoldMessenger.of(context).removeCurrentSnackBar();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('自动跟随'));
        await tester.pump();
        expect(tester.widget<IconButton>(followButton).isSelected, isTrue);
        expect(find.text('5 / 5'), findsOneWidget);
        expect(find.text('DR (6)'), findsOneWidget);
        expect(find.text('GGA UTC: 12:34:56.00'), findsOneWidget);

        final viewport = Rect.fromLTWH(0, 24, size.width, size.height - 48);
        for (final label in [
          '定位结果',
          'DR (6)',
          '5 / 5',
          'GGA UTC: 12:34:56.00',
        ]) {
          for (final element in find.text(label).evaluate()) {
            final labelFinder = find.byElementPredicate((e) => e == element);
            final rect = Rect.fromPoints(
              tester.getTopLeft(labelFinder),
              tester.getBottomRight(labelFinder),
            );
            expect(
              viewport.contains(rect.topLeft),
              isTrue,
              reason: '$label starts outside screen',
            );
            expect(
              viewport.contains(rect.bottomRight),
              isTrue,
              reason: '$label ends outside screen',
            );
          }
        }
        for (final tooltip in [
          '导入定位文件',
          '自动跟随',
          '恢复北向（上北下南）',
          '隐藏时间轴',
          '清除轨迹',
        ]) {
          expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget);
        }
        final title = find.text('定位结果');
        final titleParagraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: title, matching: find.byType(RichText)),
        );
        expect(titleParagraph.didExceedMaxLines, isFalse);
        expect(
          tester.getRect(title).width,
          greaterThanOrEqualTo(56),
          reason:
              'The restored button must not squeeze the title into tiny text',
        );
        expect(
          tester.getBottomRight(title).dx,
          lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('导入定位文件')).dx),
          reason: 'The full title must fit before the toolbar buttons',
        );

        final map = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        map.rotate(73);
        await tester.pump();
        final center = map.camera.center;
        final zoom = map.camera.zoom;
        expect(map.camera.rotation, 73);
        await tester.tap(find.byTooltip('恢复北向（上北下南）'));
        await tester.pump();
        expect(map.camera.rotation, 0);
        expect(map.camera.center, center);
        expect(map.camera.zoom, zoom);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('查看定位详情'));
        await tester.pumpAndSettle();
        expect(find.text('定位详情'), findsOneWidget);
        expect(find.text('参与定位的卫星'), findsOneWidget);
        expect(find.text('水平精度因子 HDOP'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭定位详情'));
        await tester.pumpAndSettle();
        expect(find.text('定位详情'), findsNothing);
        expect(map.camera.center, center);

        await tester.tap(find.byTooltip('清除轨迹'));
        await tester.pump();
        expect(_mapPoints(tester), isEmpty);
        expect(find.byType(Slider), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }, createHttpClient: (_) => _TileHttpClient());
    });
  }

  for (final (size, scale) in [
    (const Size(320, 640), 1.0),
    (const Size(320, 640), 2.0),
    (const Size(640, 360), 1.0),
  ]) {
    testWidgets(
      'Mobile mixed positioning supports PPP and IMU without legend at $size / $scale',
      (tester) async {
        input.writeAsBytesSync([
          ...input.readAsBytesSync(),
          ..._imuPositionFrame(1),
          ..._imuPositionFrame(2),
        ]);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final previewKey = GlobalKey();
        await HttpOverrides.runZoned(() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: mobileTheme(ThemeData(fontFamily: 'SourceHanSansHWSC')),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: RepaintBoundary(key: previewKey, child: child!),
              ),
              home: MobilePositioningPage(
                mobileLayout: true,
                onOpenDrawer: () {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await tester.tap(find.byTooltip('导入定位文件'));
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (find.textContaining('文件解析完成').evaluate().isEmpty &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              await tester.pump();
            }
          });
          expect(find.text('文件解析完成，共载入 8 个轨迹点'), findsOneWidget);
          expect(_mapPoints(tester), hasLength(8));
          expect(
            tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar,
            isNull,
          );
          ScaffoldMessenger.of(
            tester.element(find.byType(MobilePositioningPage)),
          ).removeCurrentSnackBar();
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('图层管理'));
          await tester.pumpAndSettle();
          for (final type in ['gga', 'pppsol', 'imu']) {
            expect(find.byKey(ValueKey('layer-visible-$type')), findsOneWidget);
          }
          await tester.tap(find.text('全部隐藏'));
          await tester.pumpAndSettle();
          expect(_mapPoints(tester), isEmpty);
          for (final (type, label, count) in [
            ('pppsol', 'PPP UTC:', 1),
            ('imu', 'IMU UTC:', 2),
          ]) {
            await tester.ensureVisible(
              find.byKey(ValueKey('layer-visible-$type')),
            );
            await tester.tap(find.byKey(ValueKey('layer-visible-$type')));
            await tester.pumpAndSettle();
            expect(_mapPoints(tester), hasLength(count));
            await tester.ensureVisible(find.byTooltip('关闭图层管理'));
            await tester.tap(find.byTooltip('关闭图层管理'));
            await tester.pumpAndSettle();
            expect(find.textContaining(label), findsOneWidget);
            expect(find.text('$count / $count'), findsOneWidget);
            expect(
              tester
                  .widget<Scaffold>(find.byType(Scaffold))
                  .bottomNavigationBar,
              isNull,
            );
            if (type == 'imu' &&
                const bool.fromEnvironment('CAPTURE_UI_PREVIEWS')) {
              await tester.runAsync(() async {
                final boundary =
                    previewKey.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary;
                final image = await boundary.toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/ui-previews/mobile-imu-position-${size.width.toInt()}-$scale.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
            await tester.tap(find.byTooltip('查看定位详情'));
            await tester.pumpAndSettle();
            expect(
              find.text(type == 'imu' ? 'GNSS / Fusion' : '精度因子 DOP 1'),
              findsOneWidget,
            );
            if (type == 'imu') {
              expect(find.text('30.52000200'), findsOneWidget);
              expect(find.text('114.35000000'), findsOneWidget);
              await tester.scrollUntilVisible(
                find.text('角速度（X / Y / Z）'),
                160,
                scrollable: find.byType(Scrollable).last,
              );
              expect(find.text('角速度（X / Y / Z）').hitTestable(), findsOneWidget);
            }
            await tester.ensureVisible(find.byTooltip('关闭定位详情'));
            await tester.tap(find.byTooltip('关闭定位详情'));
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('图层管理'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('全部隐藏'));
            await tester.pumpAndSettle();
          }
          expect(find.byTooltip('查看定位详情'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }, createHttpClient: (_) => _TileHttpClient());
      },
    );

    testWidgets('Device home and drawer preserve live GGA at $size / $scale', (
      tester,
    ) async {
      final events = StreamController<dynamic>.broadcast(sync: true);
      const channel = MethodChannel('test/map_ble');
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      final bluetooth = GnssBleService(methods: channel, events: events.stream);
      late GgaLogService logs;
      await tester.runAsync(() async {
        logs = GgaLogService(
          messages: bluetooth.ggaStream,
          directory: () async => Directory('${directory.path}/GGA'),
          clock: () => DateTime.utc(2026, 9, 18),
        );
        await logs.ready;
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          logs.dispose();
          var closed = false;
          unawaited(logs.flush().then((_) => closed = true));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!closed && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          expect(closed, isTrue);
        });
        bluetooth.dispose();
        await events.close();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      await HttpOverrides.runZoned(() async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'SourceHanSansHWSC'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                padding: const EdgeInsets.only(top: 24, bottom: 24),
              ),
              child: AndroidAppFrame(child: child!),
            ),
            home: AndroidHomePage(bluetooth: bluetooth, logs: logs),
          ),
        );
        await tester.pump();
        expect(find.text('设备连接'), findsOneWidget);
        expect(find.text('未连接设备'), findsOneWidget);
        expect(find.byType(FlutterMap), findsNothing);
        await tester.ensureVisible(find.text('扫描设备'));
        await tester.pump();
        await tester.tap(find.text('扫描设备'));
        await tester.pumpAndSettle();
        expect(calls, contains('startScan'));
        events.add({
          'type': 'device',
          'id': '01:02:03:04:05:06',
          'name': 'GNSS Rover',
          'rssi': -50,
        });
        await tester.pump();
        // On short landscape screens the list remains scrollable.
        await tester.scrollUntilVisible(
          find.text('GNSS Rover'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        await tester.tap(find.text('GNSS Rover'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(calls.last, 'connect');
        events.add({'type': 'state', 'state': 'connected', 'mtu': 259});
        await tester.pump();

        void receive(String body) {
          final checksum = body.codeUnits.fold(
            0,
            (value, byte) => value ^ byte,
          );
          final line =
              '\$$body*${checksum.toRadixString(16).padLeft(2, '0')}\r\n';
          events.add({'type': 'data', 'bytes': ascii.encode(line)});
        }

        receive('GPRMC,123456,A,3031.7071,N,11421.4181,E,0,0,180926,,,A');
        await tester.pump();
        expect(_mapPoints(tester), isEmpty);
        receive(
          'GPGGA,123456.00,3031.7071,N,11421.4181,E,6,18,0.8,35.2,M,0,M,1.0,0000',
        );
        await tester.pump();
        await tester.scrollUntilVisible(
          find.text('已接收 1 条 GGA'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('已接收 1 条 GGA'), findsOneWidget);
        await tester.ensureVisible(find.text('查看定位结果'));
        await tester.pump();
        await tester.tap(find.text('查看定位结果'));
        await tester.pumpAndSettle();
        final markers = _mapPoints(tester);
        expect(markers.length, 1);
        expect(find.text('DR (6)'), findsOneWidget);
        final map = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        expect(map.camera.center, markers.single);
        final importButton = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.file_open),
        );
        expect(importButton.onPressed, isNull);
        final title = find.text('定位结果');
        expect(
          tester.getBottomRight(title).dx,
          lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('导入定位文件')).dx),
        );
        expect(find.byTooltip('恢复北向（上北下南）').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);

        final follow = followButton;
        expect(tester.widget<IconButton>(follow).isSelected, isTrue);
        final previousCenter = map.camera.center;
        await tester.tap(follow);
        await tester.pump();
        expect(tester.widget<IconButton>(follow).isSelected, isFalse);
        receive(
          'GPGGA,123457.00,3031.8071,N,11421.5181,E,4,18,0.8,35.2,M,0,M,1.0,0000',
        );
        await tester.pump();
        final secondPoint = _mapPoints(tester).last;
        expect(secondPoint, isNot(previousCenter));
        expect(map.camera.center, previousCenter);
        final zoom = map.camera.zoom;
        map.rotate(42);
        await tester.tap(follow);
        await tester.pump();
        expect(tester.widget<IconButton>(follow).isSelected, isTrue);
        expect(map.camera.center, secondPoint);
        expect(map.camera.zoom, zoom);
        expect(map.camera.rotation, 42);
        receive(
          'GPGGA,123458.00,3031.9071,N,11421.6181,E,4,18,0.8,35.2,M,0,M,1.0,0000',
        );
        await tester.pump();
        expect(map.camera.center, _mapPoints(tester).last);

        Future<void> navigate(String label) async {
          await tester.tap(find.byTooltip('打开导航'));
          await tester.pumpAndSettle();
          final drawer = find.byType(Drawer);
          expect(
            find.descendant(
              of: drawer,
              matching: find.widgetWithText(ListTile, '设备连接'),
            ),
            findsOneWidget,
          );
          expect(find.text('串口调试助手'), findsNothing);
          expect(find.text('RTK配置'), findsNothing);
          expect(find.text('卫星信息'), findsNothing);
          final item = find.descendant(
            of: drawer,
            matching: find.widgetWithText(ListTile, label),
          );
          await tester.scrollUntilVisible(
            item,
            label == '设备连接' ? -200 : 200,
            scrollable: find
                .descendant(of: drawer, matching: find.byType(Scrollable))
                .first,
          );
          await tester.pump();
          await tester.tap(item);
          await tester.pumpAndSettle();
        }

        await navigate('日志存储');
        var flushed = false;
        unawaited(logs.flush().then((_) => flushed = true));
        await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while ((!flushed || find.text('1').evaluate().isEmpty) &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.scrollUntilVisible(
          find.text('GGA20260918.txt'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('GGA20260918.txt'), findsOneWidget);
        await navigate('设备连接');
        expect(find.text('已接收 3 条 GGA'), findsOneWidget);
        expect(calls.where((call) => call == 'connect').length, 1);
        expect(calls, isNot(contains('disconnect')));
        await tester.ensureVisible(find.text('断开连接'));
        await tester.tap(find.text('断开连接'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('未连接设备'),
          -200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('未连接设备'), findsOneWidget);
        await navigate('定位结果');
        receive(
          'GPGGA,123457.00,3031.8071,N,11421.5181,E,4,18,0.8,35.2,M,0,M,1.0,0000',
        );
        await tester.pump();
        expect(_mapPoints(tester).length, 3);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.file_open),
              )
              .onPressed,
          isNotNull,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }, createHttpClient: (_) => _TileHttpClient());
    });
  }
}

List<int> _imuPositionFrame(int second) {
  final utc = ByteData(11)
    ..setUint16(4, 26, Endian.little)
    ..setUint8(6, 9)
    ..setUint8(7, 24)
    ..setUint8(8, 12)
    ..setUint8(10, second);
  final position = ByteData(20)
    ..setInt64(0, 305200000000 + second * 10000, Endian.little)
    ..setInt64(8, 1143500000000, Endian.little)
    ..setInt32(16, 35000, Endian.little);
  final payload = [
    0x50,
    11,
    ...utc.buffer.asUint8List(),
    0x68,
    20,
    ...position.buffer.asUint8List(),
    0x80,
    1,
    0x45,
  ];
  final bytes = [0x59, 0x53, second, 0, payload.length, ...payload];
  var ck1 = 0, ck2 = 0;
  for (final byte in bytes.skip(2)) {
    ck1 = (ck1 + byte) & 255;
    ck2 = (ck2 + ck1) & 255;
  }
  return [...bytes, ck1, ck2];
}

class _TestFilePicker extends FilePicker {
  _TestFilePicker(this.path);
  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(path: path, name: 'mixed.log', size: File(path).lengthSync()),
  ]);
}

// Return a local transparent tile so layout/interaction tests never need a map server.
final _transparentTile = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _TileHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _TileRequest();
  @override
  void close({bool force = false}) {}
}

class _TileRequest extends Fake implements HttpClientRequest {
  @override
  final HttpHeaders headers = _TileHeaders();
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = 0;
  @override
  bool persistentConnection = true;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<HttpClientResponse> close() async => _TileResponse();
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
}

class _TileHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String name, List<String> values) action) {
    action('date', [HttpDate.format(DateTime.now().toUtc())]);
    action('cache-control', ['max-age=86400']);
    action('content-type', ['image/png']);
  }
}

class _TileResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => _transparentTile.length;
  @override
  final HttpHeaders headers = _TileHeaders();
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => [];
  @override
  bool get persistentConnection => false;
  @override
  String get reasonPhrase => 'OK';
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_transparentTile).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Check visible observations and interactive device pins independently of the
// rendering strategy; hiding a layer must preserve its stored observations.
List<LatLng> _mapPoints(WidgetTester tester) => [
  ...tester
      .widget<TrajectoryLayer>(
        find.byType(TrajectoryLayer, skipOffstage: false),
      )
      .points
      .map((point) => point.point),
  ...tester
      .widget<MarkerLayer>(find.byType(MarkerLayer, skipOffstage: false))
      .markers
      .map((marker) => marker.point),
];
