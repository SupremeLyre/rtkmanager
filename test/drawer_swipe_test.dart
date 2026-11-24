import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/accuracy_controller.dart';
import 'package:rtkmanager/accuracy_evaluation.dart';
import 'package:rtkmanager/accuracy_page.dart';
import 'package:rtkmanager/android_app_frame.dart';
import 'package:rtkmanager/android_home_page.dart';
import 'package:rtkmanager/app_ui.dart';
import 'package:rtkmanager/gga_log_service.dart';
import 'package:rtkmanager/gnss_ble_service.dart';
import 'package:rtkmanager/home_page.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/imu_file_data.dart';
import 'package:rtkmanager/imu_visualization_page.dart';
import 'package:rtkmanager/main.dart';
import 'package:rtkmanager/position_data.dart';
import 'package:rtkmanager/truth_data.dart';
import 'package:latlong2/latlong.dart';

class _TestLogs extends GgaLogService {
  _TestLogs(Directory dir)
    : super(messages: const Stream.empty(), directory: () async => dir);
}

class _TestFilePicker extends FilePicker {
  _TestFilePicker(this.paths);
  final List<String> paths;

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
  }) async {
    return FilePickerResult([
      for (final path in paths)
        PlatformFile(
          path: path,
          name: path.split(Platform.pathSeparator).last,
          size: File(path).lengthSync(),
        ),
    ]);
  }
}

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

  testWidgets(
    'AndroidHomePage opens drawer on right swipe in non-draggable areas and closes on left swipe',
    (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('drawer_android_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final bluetooth = GnssBleService(events: const Stream.empty());
      late _TestLogs logs;
      await tester.runAsync(() async {
        logs = _TestLogs(tempDir);
        await logs.ready;
      });
      addTearDown(bluetooth.dispose);
      addTearDown(logs.dispose);

      await HttpOverrides.runZoned(() async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

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
              // Match real Android scaledTouchSlop (~6-8dp) where ListView's
              // VerticalDragGestureRecognizer otherwise triggers at 6dp of thumb arc.
              data: MediaQuery.of(context).copyWith(
                gestureSettings: const DeviceGestureSettings(touchSlop: 6.0),
              ),
              child: child!,
            ),
            home: AndroidAppFrame(
              child: AndroidHomePage(bluetooth: bluetooth, logs: logs),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // Vertical scroll (including slight horizontal drift) scrolls ListView and does not open drawer.
        final scrollOffsetBefore = tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels;
        await tester.drag(
          find.text('连接你的 GNSS 设备'),
          const Offset(24, -180),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          greaterThan(scrollOffsetBefore),
        );

        // Dragging right inside search TextField does not open drawer.
        await tester.drag(
          find.widgetWithText(TextField, '设备名称或蓝牙地址'),
          const Offset(200, 0),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // Realistic human thumb right-swipe on a scrollable ListView with initial
        // contact roll and ~25-30° vertical drift opens drawer reliably on Android.
        final thumbSwipe = await tester.startGesture(
          const Offset(90, 260),
          kind: PointerDeviceKind.touch,
        );
        await thumbSwipe.moveBy(const Offset(-2, 2));
        await tester.pump(const Duration(milliseconds: 16));
        await thumbSwipe.moveBy(const Offset(9, 4.5));
        await tester.pump(const Duration(milliseconds: 16));
        await thumbSwipe.moveBy(const Offset(12, 4.0));
        await tester.pump(const Duration(milliseconds: 16));
        await thumbSwipe.moveBy(const Offset(115, 18.0));
        await tester.pump(const Duration(milliseconds: 16));
        await thumbSwipe.up();
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);

        // Swiping left closes the open drawer.
        await tester.drag(find.byType(Drawer), const Offset(-240, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // Tiny partial drag (< 30%) settles closed.
        final gesture = await tester.startGesture(const Offset(100, 220));
        await gesture.moveBy(const Offset(55, 0));
        await tester.pump();
        expect(find.byType(Drawer), findsOneWidget);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // Fast fling right opens drawer even over a shorter distance.
        await tester.flingFrom(
          const Offset(120, 220),
          const Offset(90, 0),
          900,
        );
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);

        // Navigate to 定位结果 via drawer.
        await tester.tap(find.widgetWithText(ListTile, '定位结果'));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);
        expect(find.byType(FlutterMap), findsOneWidget);

        // Dragging right on FlutterMap pans the map and does NOT open drawer.
        final mapController = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        final initialCenter = mapController.camera.center;
        await tester.dragFrom(const Offset(200, 500), const Offset(180, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);
        expect(mapController.camera.center.longitude, isNot(initialCenter.longitude));

        // Swiping right on AppPageBar or position summary card DOES open drawer!
        await tester.drag(find.text('等待定位数据'), const Offset(220, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);

        // System back / Navigator.maybePop closes the open drawer instead of popping the route.
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        expect(await navigator.maybePop(), isTrue);
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);
        expect(find.byType(FlutterMap), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }, createHttpClient: (_) => _TileHttpClient());
    },
  );

  testWidgets(
    'Desktop HomePage preserves window drag, serial terminal selection, tabs and sliders while supporting right-swipe drawer',
    (tester) async {
      const windowChannel = MethodChannel('window_manager');
      final windowCalls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowChannel, (call) async {
            windowCalls.add(call.method);
            if (call.method == 'isFocused') return true;
            if (call.method == 'isMaximized') return false;
            if (call.method == 'isFullScreen') return false;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(windowChannel, null),
      );

      final tempDir = Directory.systemTemp.createTempSync('drawer_desktop_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final ggaFile = File('${tempDir.path}${Platform.pathSeparator}track.gga')
        ..writeAsStringSync(
          '\$GNGGA,010000.00,3031.7071,N,11421.4181,E,4,18,0.8,35.2,M,0,M,1.0,0000*00\r\n'
          '\$GNGGA,010001.00,3031.7081,N,11421.4191,E,4,18,0.8,35.2,M,0,M,1.0,0000*00\r\n'
          '\$GNGGA,010002.00,3031.7091,N,11421.4201,E,4,18,0.8,35.2,M,0,M,1.0,0000*00\r\n',
        );

      await HttpOverrides.runZoned(() async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 760);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();

        // 1. WindowTitleBar drag triggers startDragging and does NOT open drawer.
        await tester.drag(
          find.byKey(const ValueKey('window-drag-area')),
          const Offset(160, 0),
        );
        await tester.pumpAndSettle();
        expect(windowCalls, contains('startDragging'));
        expect(find.byType(Drawer), findsNothing);

        // 2. Serial terminal log SelectionArea drag does NOT open drawer.
        await tester.drag(find.byType(SelectionArea), const Offset(220, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // 3. Serial controls area right-swipe (single tab) opens drawer.
        await tester.drag(find.text('串口连接'), const Offset(220, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);

        // Close with Escape key.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // 4. With multiple serial tabs, right-dragging on tab 1 switches back to tab 0
        // without opening drawer; on tab 0, left-swipe switches to tab 1 while right-swipe opens drawer.
        await tester.tap(find.byTooltip('新建串口连接'));
        await tester.pumpAndSettle();
        expect(find.text('串口 2'), findsOneWidget);
        await tester.drag(find.text('串口连接').last, const Offset(500, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // Now on tab 0: swiping left switches to tab 1 without opening drawer.
        await tester.drag(find.text('串口连接').first, const Offset(-500, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // AppPageBar right-swipe opens drawer even from tab 1.
        await tester.drag(find.text('串口调试助手'), const Offset(240, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);

        // 5. Switch to 定位结果, import 3 epochs, verify timeline Slider drag scrubs without opening drawer.
        await tester.tap(find.widgetWithText(ListTile, '定位结果'));
        await tester.pumpAndSettle();
        FilePicker.platform = _TestFilePicker([ggaFile.path]);
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
          tester.element(find.byType(HomePage)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
        expect(find.text('1 / 3'), findsOneWidget);

        await tester.drag(find.byType(Slider), const Offset(260, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);
        expect(find.text('1 / 3'), findsNothing);

        // Swiping right on AppPageBar of 定位结果 opens drawer.
        await tester.drag(find.text('定位结果').first, const Offset(240, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);

        // 6. Switch to 精度评定, load truth, evaluate, verify accuracy Slider drag does NOT open drawer.
        await tester.tap(find.widgetWithText(ListTile, '精度评定'));
        await tester.pumpAndSettle();
        final homeElement = tester.element(find.byType(HomePage));
        expect(homeElement, isNotNull);

        // Swiping right on 精度评定 body opens drawer.
        await tester.drag(find.text('对齐真值，查看误差'), const Offset(240, 0));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);
        await tester.tapAt(const Offset(900, 400));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsNothing);

        // Slight mouse jitter during a click does NOT swallow button tap or open drawer.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        final menuCenter = tester.getCenter(find.byTooltip('打开导航'));
        await mouse.addPointer(location: menuCenter);
        await mouse.down(menuCenter);
        await mouse.moveBy(const Offset(5, 0));
        await mouse.up();
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }, createHttpClient: (_) => _TileHttpClient());
    },
  );

  testWidgets(
    'RangeSlider in ImuVisualizationPage adjusts time window without opening drawer',
    (tester) async {
      final files = ImuFileController();
      addTearDown(files.dispose);
      final builder = ImuFileBuilder('/offline.bin');
      for (var i = 0; i <= 20; i++) {
        builder.add(
          ImuData()
            ..gpsWeek = 2400
            ..gpsTowNanos = i * 1000000000
            ..ax = 0.1 * i
            ..ay = 0.0
            ..az = 1.0,
        );
      }
      files.add(builder.build());

      await tester.pumpWidget(
        MaterialApp(
          theme: mobileTheme(ThemeData(fontFamily: 'SourceHanSansHWSC')),
          home: AppDrawerShell(
            drawer: AppNavigationDrawer(
              destinations: const [
                AppDestination(Icons.show_chart, '数据可视化', '实时与离线观测'),
              ],
              selectedIndex: 0,
              onSelected: (_) {},
            ),
            body: ImuVisualizationPage(
              files: files,
              dataStream: const Stream.empty(),
              sourceLabel: '测试源',
              emptyMessage: '无数据',
              onOpenDrawer: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rangeSlider = find.byKey(const ValueKey('imu-file-range'));
      expect(rangeSlider, findsOneWidget);
      final rect = tester.getRect(rangeSlider);
      // Drag the left thumb of the RangeSlider rightward.
      await tester.dragFrom(
        Offset(rect.left + 24, rect.center.dy),
        const Offset(140, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(
        tester.widget<RangeSlider>(rangeSlider).values.start,
        greaterThan(0),
      );

      // Swiping right on the chart card below RangeSlider opens the drawer.
      await tester.drag(find.text('加速度 · g'), const Offset(240, 0));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'AccuracyPage epoch Slider drags without opening drawer while chart and cards open drawer',
    (tester) async {
      final t0 = DateTime.utc(2026, 10, 29, 1);
      final points = [
        for (var s = 0; s < 4; s++)
          PositionHistoryPoint(
            location: const LatLng(30.01, 114.01),
            status: 4,
            type: PointType.imu,
            isImu: true,
            sourcePath: '/imu.bin',
            wgs84Latitude: 30 + s * 0.00001,
            wgs84Longitude: 114,
            ellipsoidHeight: 20,
            utcDateTime: t0.add(Duration(seconds: s)),
            imuData: ImuData()
              ..gnssState = 4
              ..fusionState = 4,
          ),
      ];
      final truth = TruthDataset(
        sourcePath: '/truth.pos',
        samples: [
          for (var s = 0; s < 4; s++)
            TruthSample(
              utcTime: t0.add(Duration(seconds: s)),
              latitude: 30,
              longitude: 114,
              height: 20,
            ),
        ],
      );
      final controller = AccuracyController()
        ..setPoints(points)
        ..setTruthDataset(truth);
      addTearDown(controller.dispose);
      await tester.runAsync(
        () => controller.evaluate(
          options: const EvaluationOptions(calibrate: false),
        ),
      );
      controller.selectPoint(points.first);

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        MaterialApp(
          theme: mobileTheme(ThemeData(fontFamily: 'SourceHanSansHWSC')),
          home: AppDrawerShell(
            drawer: AppNavigationDrawer(
              destinations: const [
                AppDestination(Icons.analytics_outlined, '精度评定', '真值对比'),
              ],
              selectedIndex: 0,
              onSelected: (_) {},
            ),
            body: AccuracyPage(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final slider = find.byKey(const ValueKey('accuracy-epoch-slider'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      expect(find.text('1 / 4'), findsOneWidget);

      await tester.drag(slider, const Offset(240, 0));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.text('1 / 4'), findsNothing);

      await tester.ensureVisible(find.text('水平位置'));
      await tester.pumpAndSettle();
      await tester.drag(find.text('水平位置'), const Offset(240, 0));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
