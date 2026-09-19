import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/android_home_page.dart';
import 'package:rtkmanager/android_app_frame.dart';
import 'package:rtkmanager/gga_log_service.dart';
import 'package:rtkmanager/gnss_ble_service.dart';
import 'package:rtkmanager/positioning_page.dart';

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

  for (final (size, scale) in [
    (const Size(320, 640), 1.0),
    (const Size(360, 740), 1.3),
    (const Size(640, 360), 1.0),
    (const Size(320, 640), 2.0),
  ]) {
    testWidgets('GGA controls fit without a legend at $size / $scale', (
      tester,
    ) async {
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
            home: MobilePositioningPage(ggaOnly: true, onOpenDrawer: () {}),
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
          await tester.tap(find.byTooltip('导入 GGA 文件'));
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (find.textContaining('文件解析完成').evaluate().isEmpty &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        expect(find.text('文件解析完成，共载入 5 个轨迹点'), findsOneWidget);
        final markers = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
        expect(markers.markers.length, 5);
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
          '导入 GGA 文件',
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
          lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('导入 GGA 文件')).dx),
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
        expect(
          tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers,
          isEmpty,
        );
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
        expect(
          tester
              .widget<MarkerLayer>(
                find.byType(MarkerLayer, skipOffstage: false),
              )
              .markers,
          isEmpty,
        );
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
        final markers = tester
            .widget<MarkerLayer>(find.byType(MarkerLayer))
            .markers;
        expect(markers.length, 1);
        expect(find.text('DR (6)'), findsOneWidget);
        final map = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        expect(map.camera.center, markers.single.point);
        final importButton = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.file_open),
        );
        expect(importButton.onPressed, isNull);
        final title = find.text('定位结果');
        expect(
          tester.getBottomRight(title).dx,
          lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('导入 GGA 文件')).dx),
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
        final secondPoint = tester
            .widget<MarkerLayer>(find.byType(MarkerLayer))
            .markers
            .last
            .point;
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
        expect(
          map.camera.center,
          tester
              .widget<MarkerLayer>(find.byType(MarkerLayer))
              .markers
              .last
              .point,
        );

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
        expect(
          tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers.length,
          3,
        );
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
