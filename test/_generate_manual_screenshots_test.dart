import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:rtkmanager/accuracy_controller.dart';
import 'package:rtkmanager/accuracy_page.dart';
import 'package:rtkmanager/app_ui.dart';
import 'package:rtkmanager/home_page.dart';
import 'package:rtkmanager/imu_batch_decode_page.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/imu_file_data.dart';
import 'package:rtkmanager/main.dart';
import 'package:rtkmanager/ntrip_service.dart';
import 'package:rtkmanager/position_data.dart';
import 'package:rtkmanager/positioning_page.dart';
import 'package:rtkmanager/rtk_config_page.dart';
import 'package:rtkmanager/satellite_info.dart';
import 'package:rtkmanager/satellite_page.dart';
import 'package:rtkmanager/serial_debug_page.dart';
import 'package:rtkmanager/serial_imu_page.dart';
import 'package:rtkmanager/serial_service.dart';
import 'package:rtkmanager/truth_data.dart';

const _outDir =
    r'C:\Users\61498\.gemini\antigravity-cli\brain\185721bd-6f17-434b-915a-88233bc398d9\scratch\manual_screenshots';

class _MockPort extends SerialService {
  _MockPort(this.name) : super.create();
  final String name;
  final frames = StreamController<ImuData>.broadcast();
  @override
  String get currentPortName => name;
  @override
  bool get isOpen => true;
  @override
  Stream<ImuData> get imuDataStream => frames.stream;
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
          name: path.split(RegExp(r'[/\\]')).last,
          size: File(path).lengthSync(),
        ),
    ]);
  }
}

Future<Uint8List> _generateMapTilePng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = 256.0;

  canvas.drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()..color = const Color(0xFFF3F6F9),
  );

  canvas.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(28, 36, 92, 74),
      const Radius.circular(8),
    ),
    Paint()..color = const Color(0xFFE4F0E6),
  );

  final water = Path()
    ..moveTo(188, 0)
    ..quadraticBezierTo(168, 96, 256, 152)
    ..lineTo(256, 0)
    ..close();
  canvas.drawPath(water, Paint()..color = const Color(0xFFDDECF6));

  final minorRoad = Paint()
    ..color = const Color(0xFFE5EAEF)
    ..strokeWidth = 2.5
    ..style = PaintingStyle.stroke;
  for (final pos in [48.0, 112.0, 176.0, 224.0]) {
    canvas.drawLine(Offset(pos, 0), Offset(pos, size), minorRoad);
    canvas.drawLine(Offset(0, pos), Offset(size, pos), minorRoad);
  }

  final casing = Paint()
    ..color = const Color(0xFFD4DCE4)
    ..strokeWidth = 9
    ..style = PaintingStyle.stroke;
  final fill = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..strokeWidth = 6
    ..style = PaintingStyle.stroke;
  for (final p in [casing, fill]) {
    canvas.drawLine(const Offset(0, 144), const Offset(size, 96), p);
    canvas.drawLine(const Offset(84, 0), const Offset(132, size), p);
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(256, 256);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return byteData!.buffer.asUint8List();
}

class _MapTileHttpClient extends Fake implements HttpClient {
  _MapTileHttpClient(this.tileBytes);
  final Uint8List tileBytes;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _MapTileRequest(tileBytes);
  @override
  void close({bool force = false}) {}
}

class _MapTileRequest extends Fake implements HttpClientRequest {
  _MapTileRequest(this.tileBytes);
  final Uint8List tileBytes;
  @override
  final HttpHeaders headers = _MapTileHeaders();
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
  Future<HttpClientResponse> close() async => _MapTileResponse(tileBytes);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
}

class _MapTileHeaders extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String name, List<String> values) action) {
    action('date', [HttpDate.format(DateTime.now().toUtc())]);
    action('cache-control', ['max-age=86400']);
    action('content-type', ['image/png']);
  }
}

class _MapTileResponse extends Stream<List<int>> implements HttpClientResponse {
  _MapTileResponse(this.tileBytes);
  final Uint8List tileBytes;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => tileBytes.length;
  @override
  final HttpHeaders headers = _MapTileHeaders();
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
  }) => Stream<List<int>>.value(tileBytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<int> _buildImuNavFrame({
  required int tid,
  required DateTime utcTime,
  required double latDeg,
  required double lonDeg,
  required double altM,
  required double rollDeg,
  required double pitchDeg,
  required double yawDeg,
  required double ve,
  required double vn,
  required double vu,
  required int statusByte,
  bool includeRawImu = true,
}) {
  final utc = ByteData(11)
    ..setUint32(0, utcTime.millisecond, Endian.little)
    ..setUint16(4, utcTime.year - 2000, Endian.little)
    ..setUint8(6, utcTime.month)
    ..setUint8(7, utcTime.day)
    ..setUint8(8, utcTime.hour)
    ..setUint8(9, utcTime.minute)
    ..setUint8(10, utcTime.second);

  final pos = ByteData(20)
    ..setInt64(0, (latDeg * 1e10).round(), Endian.little)
    ..setInt64(8, (lonDeg * 1e10).round(), Endian.little)
    ..setInt32(16, (altM * 1000).round(), Endian.little);

  final att = ByteData(12)
    ..setInt32(0, (pitchDeg * 1e6).round(), Endian.little)
    ..setInt32(4, (rollDeg * 1e6).round(), Endian.little)
    ..setInt32(8, (yawDeg * 1e6).round(), Endian.little);

  final vel = ByteData(12)
    ..setInt32(0, (ve * 1000).round(), Endian.little)
    ..setInt32(4, (vn * 1000).round(), Endian.little)
    ..setInt32(8, (vu * 1000).round(), Endian.little);

  final rawAcc = ByteData(12)
    ..setInt32(0, 12000, Endian.little)
    ..setInt32(4, -8000, Endian.little)
    ..setInt32(8, 998000, Endian.little);

  final rawGyro = ByteData(12)
    ..setInt32(0, 150000, Endian.little)
    ..setInt32(4, -220000, Endian.little)
    ..setInt32(8, 850000, Endian.little);

  final temp = ByteData(2)..setInt16(0, 3420, Endian.little);

  final payload = <int>[
    if (includeRawImu) ...[
      0x10,
      12,
      ...rawAcc.buffer.asUint8List(),
      0x20,
      12,
      ...rawGyro.buffer.asUint8List(),
      0x01,
      2,
      ...temp.buffer.asUint8List(),
    ],
    0x50,
    11,
    ...utc.buffer.asUint8List(),
    0x68,
    20,
    ...pos.buffer.asUint8List(),
    0x40,
    12,
    ...att.buffer.asUint8List(),
    0x70,
    12,
    ...vel.buffer.asUint8List(),
    0x80,
    1,
    statusByte,
    0x85,
    1,
    3,
  ];
  final headerAndBody = <int>[
    0x59,
    0x53,
    tid & 0xFF,
    (tid >> 8) & 0xFF,
    payload.length,
    ...payload,
  ];
  var ck1 = 0, ck2 = 0;
  for (final b in headerAndBody.skip(2)) {
    ck1 = (ck1 + b) & 0xFF;
    ck2 = (ck2 + ck1) & 0xFF;
  }
  return [...headerAndBody, ck1, ck2];
}

String _formatNmeaCoord(double deg, {required bool isLat}) {
  final absDeg = deg.abs();
  final whole = absDeg.floor();
  final minutes = (absDeg - whole) * 60.0;
  final degStr = whole.toString().padLeft(isLat ? 2 : 3, '0');
  final minStr = minutes.toStringAsFixed(6).padLeft(9, '0');
  return '$degStr$minStr';
}

String _buildGgaLine(
  DateTime utc,
  double lat,
  double lon,
  double alt,
  int qual,
) {
  final hh = utc.hour.toString().padLeft(2, '0');
  final mm = utc.minute.toString().padLeft(2, '0');
  final ss = utc.second.toString().padLeft(2, '0');
  final latStr = _formatNmeaCoord(lat, isLat: true);
  final lonStr = _formatNmeaCoord(lon, isLat: false);
  final body =
      'GNGGA,$hh$mm$ss.00,$latStr,N,$lonStr,E,$qual,24,0.68,${alt.toStringAsFixed(2)},M,-13.5,M,1.0,0000';
  var cs = 0;
  for (final code in body.codeUnits) {
    cs ^= code;
  }
  return '\$$body*${cs.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}

Future<void> _savePng(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String fileName,
) async {
  await tester.runAsync(() async {
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_outDir${Platform.pathSeparator}$fileName');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<GlobalKey> _pumpDesktopWindow(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1024, 700),
}) async {
  // Tear down any previous MaterialApp / Navigator modal overlays cleanly
  await tester.pumpWidget(const SizedBox());
  await tester.pump();

  final boundary = GlobalKey();
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      debugShowCheckedModeBanner: false,
      title: 'RTK Manager',
      theme: mobileTheme(
        ThemeData(
          platform: TargetPlatform.windows,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
          fontFamily: 'SourceHanSansHWSC',
        ),
      ),
      builder: (context, appChild) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: const TextScaler.linear(1.0),
          disableAnimations: true,
        ),
        child: RepaintBoundary(key: boundary, child: appChild!),
      ),
      home: CustomWindowFrame(child: child),
    ),
  );
  return boundary;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader(
      'SourceHanSansHWSC',
    )..addFont(rootBundle.load('fonts/SourceHanSansHWSC-Regular.otf'))).load();
    await (FontLoader(
      'SourceCodePro',
    )..addFont(rootBundle.load('fonts/SourceCodePro-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('Generate all 9 PC manual screenshots', (tester) async {
    final surveyDir = Directory('Survey_20261123')
      ..createSync(recursive: true);
    final cacheDir = Directory.systemTemp.createTempSync('rtk_tile_cache_');
    ServerSocket? mockCaster;
    final clientSockets = <Socket>[];

    const pathProviderChannel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProviderChannel,
      (call) async => cacheDir.path,
    );

    const windowManagerChannel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowManagerChannel,
      (call) async {
        if (call.method == 'isMaximized' || call.method == 'isFullScreen') {
          return false;
        }
        return null;
      },
    );

    addTearDown(() async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pathProviderChannel,
        null,
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowManagerChannel,
        null,
      );
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
      await tester.binding.setSurfaceSize(null);
      SerialService.connectedServices.value = [];
      await NtripService().disconnect();
      for (final s in clientSockets) {
        s.destroy();
      }
      await mockCaster?.close();
      if (surveyDir.existsSync()) {
        surveyDir.deleteSync(recursive: true);
      }
      if (cacheDir.existsSync()) {
        try {
          cacheDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    await tester.runAsync(() async {
      mockCaster = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      mockCaster!.listen((socket) {
        clientSockets.add(socket);
        socket.listen((data) async {
          final req = utf8.decode(data, allowMalformed: true);
          if (req.startsWith('GET / ')) {
            socket.write(
              'SOURCETABLE 200 OK\r\n'
              'STR;RTCM33_GRCEJ;WHU;RTCM 3.3;1074,1084,1094,1124;2;BDS+GPS+GAL+GLO;WHUSGG;CHN;30.53;114.36;1;1;sNTRIP;none;B;N;0;\r\n'
              'STR;RTCM33_GRCE;WHU;RTCM 3.3;1074,1084,1094,1124;2;BDS+GPS+GAL;WHUSGG;CHN;30.53;114.36;1;1;sNTRIP;none;B;N;0;\r\n'
              'ENDSOURCETABLE\r\n',
            );
            await socket.flush();
            await socket.close();
          } else {
            socket.write('ICY 200 OK\r\n\r\n');
            await socket.flush();
          }
        });
      });
    });

    // =========================================================================
    // 1. fig1_drawer.png: HomePage with Navigation Drawer Open (7 PC modules)
    // =========================================================================
    var boundary = await _pumpDesktopWindow(
      tester,
      const HomePage(),
      size: const Size(1024, 700),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    if (find.byTooltip('清空接收区').hitTestable().evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('清空接收区').hitTestable().first);
      await tester.pump();
    }
    await tester.tap(find.byTooltip('打开导航').first);
    await tester.pumpAndSettle();
    expect(find.text('精度评定'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _savePng(tester, boundary, 'fig1_drawer.png');

    // =========================================================================
    // 2. fig2_serial.png: SerialDebugPage with Main + Serial 2, 460800, HEX+IMU
    // =========================================================================
    await tester.runAsync(() async {
      await NtripService().connect(
        '127.0.0.1',
        mockCaster!.port,
        'RTCM33_GRCEJ',
        'whusgg_rtk',
        '123456',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!NtripService().isConnected && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    boundary = await _pumpDesktopWindow(
      tester,
      SerialDebugPage(onOpenDrawer: () {}),
      size: const Size(1024, 700),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建串口连接'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    if (find.byTooltip('清空接收区').hitTestable().evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('清空接收区').hitTestable().first);
      await tester.pump();
    }

    final baudDropdown = find
        .byType(DropdownButtonFormField<int>)
        .hitTestable();
    tester.widget<DropdownButtonFormField<int>>(baudDropdown.first).onChanged!(
      460800,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'HEX').hitTestable());
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, '解析IMU').hitTestable());
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextField, '发送内容').hitTestable(),
      r'$PCAS03,1,0,0,1,1,0,0,0*03',
    );
    await tester.tap(
      find.widgetWithText(FilterChip, r'自动添加 \r\n').hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _savePng(tester, boundary, 'fig2_serial.png');

    // =========================================================================
    // 3. fig3_rtk.png: RtkConfigPage with Mountpoint, Output Port & Connected!
    // =========================================================================
    await tester.runAsync(() => NtripService().disconnect());
    boundary = await _pumpDesktopWindow(
      tester,
      RtkConfigPage(
        onOpenDrawer: () {},
        listSerialPorts: () => ['COM3', 'COM4', 'COM5', 'COM6'],
      ),
      size: const Size(1024, 900),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'IP 地址 / 域名'),
      '127.0.0.1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '端口'),
      '${mockCaster!.port}',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '用户名'),
      'whusgg_cors',
    );
    await tester.enterText(find.widgetWithText(TextField, '密码'), '12345678');
    await tester.pump();

    await tester.runAsync(() async {
      await tester.tap(find.text('获取列表'));
      await Future<void>.delayed(const Duration(milliseconds: 220));
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加输出串口'));
    await tester.pumpAndSettle();

    final strDropdowns = find.byType(DropdownButtonFormField<String>);
    tester
        .widget<DropdownButtonFormField<String>>(strDropdowns.last)
        .onChanged!('COM6');
    final rtkBaudDropdowns = find.byType(DropdownButtonFormField<int>);
    tester
        .widget<DropdownButtonFormField<int>>(rtkBaudDropdowns.last)
        .onChanged!(460800);
    await tester.pump();

    await tester.ensureVisible(find.text('自动重连'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动重连'));
    await tester.pump();

    await tester.ensureVisible(find.text('连接 NTRIP'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('连接 NTRIP'));
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!NtripService().isConnected && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'IP 地址 / 域名'),
      'sdk.pnt.10086.cn',
    );
    await tester.enterText(find.widgetWithText(TextField, '端口'), '8002');
    NtripService().addLog(
      r'GGA 发送成功: $GNGGA,081522.00,3031.7071,N,11421.4181,E,4,24,0.65,35.24,M,-13.5,M,1.0,0000*4D',
    );
    NtripService().addLog(
      r'GGA 发送成功: $GNGGA,081523.00,3031.7073,N,11421.4185,E,4,24,0.65,35.25,M,-13.5,M,1.0,0000*48',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _savePng(tester, boundary, 'fig3_rtk.png');

    // =========================================================================
    // 4 & 5. fig4_pos_map.png & fig5_pos_layers.png: PositioningPage & Layers
    // =========================================================================
    late Uint8List mapTilePng;
    await tester.runAsync(() async {
      mapTilePng = await _generateMapTilePng();
    });

    final baseUtc = DateTime.utc(2026, 11, 23, 8, 15, 0);
    final ggaLines = <String>[];
    final insBytes = <int>[];
    final truthSamples = <TruthSample>[];

    for (var i = 0; i < 45; i++) {
      final t = i.toDouble();
      final utc = baseUtc.add(Duration(seconds: i));
      final lat = 30.5280 + 0.000055 * t + 0.00018 * math.sin(t / 12.0);
      final lon = 114.3540 + 0.000075 * t + 0.00012 * math.cos(t / 15.0);
      final alt = 34.8 + 0.3 * math.sin(t / 10.0);
      final ve = 4.2 + 0.4 * math.cos(t / 8.0);
      final vn = 3.5 + 0.3 * math.sin(t / 10.0);
      final yaw = 48.0 + 12.0 * math.sin(t / 11.0);

      truthSamples.add(
        TruthSample(
          utcTime: utc,
          latitude: lat,
          longitude: lon,
          height: alt,
          velocityEast: ve,
          velocityNorth: vn,
          velocityUp: 0.02,
          roll: 0.4,
          pitch: 0.8,
          heading: yaw,
        ),
      );

      final isTunnel = i >= 22 && i <= 27;
      if (!isTunnel) {
        final ggaQual = (i >= 18 && i <= 21) ? 5 : 4;
        ggaLines.add(
          _buildGgaLine(utc, lat + 0.000002, lon - 0.000002, alt, ggaQual),
        );
      }
      insBytes.addAll(
        _buildImuNavFrame(
          tid: 1000 + i * 100,
          utcTime: utc,
          latDeg: lat + 0.0000015 * math.sin(t),
          lonDeg: lon + 0.0000015 * math.cos(t),
          altM: alt + 0.05,
          rollDeg: 0.45 + 0.1 * math.sin(t / 5),
          pitchDeg: 0.82 + 0.1 * math.cos(t / 6),
          yawDeg: yaw + 0.2,
          ve: ve,
          vn: vn,
          vu: 0.02,
          statusByte: isTunnel ? 0x05 : 0x44,
        ),
      );
    }

    final ggaFile = File(
      '${surveyDir.path}${Platform.pathSeparator}gnss_20261123.gga',
    )..writeAsStringSync('${ggaLines.join('\r\n')}\r\n');
    final insFile = File(
      '${surveyDir.path}${Platform.pathSeparator}ins_20261123.bin',
    )..writeAsBytesSync(insBytes);

    final posAccuracy = AccuracyController();
    final posVis = ImuFileController();
    addTearDown(posAccuracy.dispose);
    addTearDown(posVis.dispose);

    await HttpOverrides.runZoned(() async {
      boundary = await _pumpDesktopWindow(
        tester,
        MobilePositioningPage(
          onOpenDrawer: () {},
          accuracy: posAccuracy,
          visualization: posVis,
          onShowAccuracy: () {},
          onShowVisualization: () {},
        ),
        size: const Size(1024, 720),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pumpAndSettle();

      FilePicker.platform = _TestFilePicker([ggaFile.path, insFile.path]);
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('从文件导入IMU定位数据'));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (find.textContaining('文件解析完成').evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump();
        }
        posAccuracy.setTruthDataset(
          TruthDataset(
            sourcePath: r'D:\Survey\truth_ref_20261123.pos',
            samples: truthSamples,
          ),
        );
        await posAccuracy.evaluate();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      final ctx = tester.element(find.byType(MobilePositioningPage));
      ScaffoldMessenger.of(ctx).clearSnackBars();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _savePng(tester, boundary, 'fig4_pos_map.png');

      await tester.tap(find.byTooltip('图层管理'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _savePng(tester, boundary, 'fig5_pos_layers.png');

      // Close modal bottom sheet cleanly before moving to next page
      Navigator.of(ctx).pop();
      await tester.pumpAndSettle();
    }, createHttpClient: (_) => _MapTileHttpClient(mapTilePng));

    // =========================================================================
    // 6. fig6_satellite.png: SatellitePage with Multi-GNSS SNR & Sky Plot
    // =========================================================================
    boundary = await _pumpDesktopWindow(
      tester,
      SatellitePage(onOpenDrawer: () {}),
      size: const Size(1024, 720),
    );
    await tester.pump();
    final gsvSentences = [
      r'$GPGSV,2,1,08,02,68,045,46,05,52,135,44,12,41,220,41,17,74,310,48,1*60',
      r'$GPGSV,2,2,08,19,28,082,37,23,61,190,45,25,33,268,39,31,19,340,33,1*60',
      r'$GBGSV,3,1,10,01,55,148,45,03,60,205,46,06,78,030,49,08,44,065,42,1*70',
      r'$GBGSV,3,2,10,11,66,315,47,14,38,118,41,16,71,252,48,21,49,012,44,1*70',
      r'$GBGSV,3,3,10,27,29,175,38,33,53,290,43,1*70',
      r'$GAGSV,2,1,06,04,64,095,45,09,47,210,42,15,72,330,47,21,35,155,39,7*60',
      r'$GAGSV,2,2,06,27,51,275,43,30,24,040,36,7*60',
      r'$GLGSV,2,1,05,65,58,022,44,66,43,108,40,72,69,245,46,73,31,318,37,1*60',
      r'$GLGSV,2,2,05,81,22,195,34,1*60',
      r'$GQGSV,1,1,02,02,63,132,43,04,48,162,40,1*60',
    ];
    await tester.runAsync(() async {
      for (final s in gsvSentences) {
        SatelliteService().processGsvSentence(s);
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _savePng(tester, boundary, 'fig6_satellite.png');

    // =========================================================================
    // 7. fig7_decode.png: ImuBatchDecodePage with Queued & Completed BIN Files
    // =========================================================================
    final decodeFile1 = File(
      '${surveyDir.path}${Platform.pathSeparator}COM5-2026-11-23-09-30-00.dat',
    )..writeAsBytesSync(insBytes);
    final decodeFile2 = File(
      '${surveyDir.path}${Platform.pathSeparator}ins_survey_run02.bin',
    )..writeAsBytesSync(insBytes);

    FilePicker.platform = _TestFilePicker([decodeFile1.path, decodeFile2.path]);
    boundary = await _pumpDesktopWindow(
      tester,
      ImuBatchDecodePage(onOpenDrawer: () {}),
      size: const Size(1024, 980),
    );
    await tester.pumpAndSettle();

    for (final chipLabel in [
      '输出欧拉角',
      '输出位置(经纬高)',
      '输出速度(东/北/天)',
      '输出状态',
      '输出温度',
    ]) {
      final chip = find.widgetWithText(FilterChip, chipLabel);
      if (chip.evaluate().isNotEmpty &&
          !tester.widget<FilterChip>(chip).selected) {
        await tester.ensureVisible(chip);
        await tester.pumpAndSettle();
        await tester.tap(chip);
        await tester.pump();
      }
    }

    await tester.ensureVisible(find.text('导入文件'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('导入文件'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('开始解码'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('开始解码'));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _savePng(tester, boundary, 'fig7_decode.png');

    // =========================================================================
    // 8. fig8_visualization.png: SerialImuPage with Offline Multi-Axis Curves
    // =========================================================================
    final fileBuilder = ImuFileBuilder(
      r'D:\Survey\COM5-2026-11-23-09-30-00.dat',
    );
    for (var i = 0; i <= 480; i++) {
      final sec = i * 0.25;
      final d = ImuData()
        ..gpsWeek = 2446
        ..gpsTowNanos = (300000 * 1000000000) + (sec * 1e9).round()
        ..startupStage = 3
        ..fusionState = 4
        ..ax = 0.06 * math.sin(sec / 4.5) + 0.02 * math.cos(sec * 1.3)
        ..ay = 0.09 * math.cos(sec / 6.0) + 0.015 * math.sin(sec * 0.9)
        ..az = 0.998 + 0.025 * math.sin(sec * 1.8)
        ..wx = 1.8 * math.sin(sec / 5.0)
        ..wy = 1.2 * math.cos(sec / 7.0)
        ..wz =
            14.0 *
            math.sin(sec / 9.5) *
            math.exp(-((sec - 60) * (sec - 60)) / 900)
        ..mx = 24.5 + 6.2 * math.cos(sec / 11.0)
        ..my = -8.3 + 6.2 * math.sin(sec / 11.0)
        ..mz = -38.4 + 0.8 * math.sin(sec / 4.0)
        ..roll = 1.1 * math.sin(sec / 8.0)
        ..pitch = 1.6 * math.cos(sec / 10.0)
        ..yaw = 65.0 + 35.0 * math.sin(sec / 18.0)
        ..ve = 5.5 + 2.2 * math.sin(sec / 14.0)
        ..vn = 4.1 + 1.8 * math.cos(sec / 16.0)
        ..vu = 0.12 * math.sin(sec / 6.0);
      fileBuilder.add(d);
    }
    final visController = ImuFileController()..add(fileBuilder.build());
    final mockPortA = _MockPort('COM5');
    final mockPortB = _MockPort('COM6');
    SerialService.connectedServices.value = [mockPortA, mockPortB];
    addTearDown(() async {
      visController.dispose();
      await mockPortA.frames.close();
      await mockPortB.frames.close();
      mockPortA.dispose();
      mockPortB.dispose();
    });

    boundary = await _pumpDesktopWindow(
      tester,
      SerialImuPage(
        files: visController,
        onOpenDrawer: () {},
        onOpenSerial: () {},
        active: true,
      ),
      size: const Size(1024, 780),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _savePng(tester, boundary, 'fig8_visualization.png');

    // =========================================================================
    // 9. fig9_accuracy.png: AccuracyPage with Calibrated Error Chart & Stats
    // =========================================================================
    final accPoints = <PositionHistoryPoint>[];
    final accTruth = <TruthSample>[];
    final accStart = DateTime.utc(2026, 11, 23, 9, 0, 0);
    for (var i = 0; i < 120; i++) {
      final s = i.toDouble();
      final travel = math.max(0.0, s - 25.0);
      final time = accStart.add(Duration(seconds: i));
      final lat = 30.528 + travel * 0.000006;
      final lon = 114.354 + travel * 0.000011;
      final h = 34.5 + 0.03 * math.sin(s / 10.0);
      final ve = travel == 0 ? 0.0 : 3.2 + 0.3 * math.sin(travel / 12.0);
      final vn = travel == 0 ? 0.0 : 2.4 + 0.2 * math.cos(travel / 15.0);
      final vu = travel == 0 ? 0.0 : 0.02 * math.sin(travel / 9.0);
      final roll = 0.35 * math.sin(s / 24.0);
      final pitch = 0.55 * math.cos(s / 28.0);
      final heading = 54.0 + 0.12 * travel;

      final eErr =
          0.16 + 0.016 * math.sin(s * 0.42) + 0.022 * math.sin(travel / 9.0);
      final nErr =
          -0.11 + 0.019 * math.cos(s * 0.35) + 0.015 * math.cos(travel / 11.0);
      final uErr = 0.28 + 0.032 * math.sin(s * 0.24);

      accTruth.add(
        TruthSample(
          utcTime: time,
          latitude: lat,
          longitude: lon,
          height: h,
          velocityEast: ve,
          velocityNorth: vn,
          velocityUp: vu,
          roll: roll,
          pitch: pitch,
          heading: heading,
        ),
      );

      final solLat = lat + nErr / 111319.49;
      final solLon = lon + eErr / (111319.49 * math.cos(lat * math.pi / 180.0));
      accPoints.add(
        PositionHistoryPoint(
          location: LatLng(solLat, solLon),
          status: 4,
          type: PointType.imu,
          isImu: true,
          sourcePath: r'D:\Survey\20261123\ins_trajectory.bin',
          wgs84Latitude: solLat,
          wgs84Longitude: solLon,
          ellipsoidHeight: h + uErr,
          utcDateTime: time,
          velocityEast: ve + 0.018 * math.sin(s / 7.0),
          velocityNorth: vn - 0.014 * math.cos(s / 8.0),
          velocityUp: vu + 0.008 * math.sin(s / 5.0),
          imuData: ImuData()
            ..gnssState = 4
            ..fusionState = 4
            ..startupStage = 3
            ..roll = roll + 0.28 + 0.05 * math.sin(s / 11.0)
            ..pitch = pitch - 0.19 + 0.04 * math.cos(s / 13.0)
            ..yaw = heading + 0.85 + 0.14 * math.sin(s / 15.0),
        ),
      );
    }

    final accCtrl = AccuracyController();
    addTearDown(accCtrl.dispose);
    accCtrl.setPoints(accPoints);
    accCtrl.setTruthDataset(
      TruthDataset(
        sourcePath: r'D:\Survey\20261123\truth_ie_postproc.pos',
        samples: accTruth,
      ),
    );
    await tester.runAsync(() async {
      await accCtrl.evaluate();
    });
    accCtrl.selectPoint(accPoints[72]);

    boundary = await _pumpDesktopWindow(
      tester,
      AccuracyPage(
        controller: accCtrl,
        onOpenDrawer: () {},
        onShowPositioning: () {},
      ),
      size: const Size(1024, 820),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _savePng(tester, boundary, 'fig9_accuracy.png');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
