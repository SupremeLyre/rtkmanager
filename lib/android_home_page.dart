import 'dart:async';

import 'package:flutter/material.dart';

import 'device_connection_page.dart';
import 'gga_log_page.dart';
import 'gga_log_service.dart';
import 'gnss_ble_service.dart';
import 'positioning_page.dart';
import 'phone_capture_page.dart';
import 'phone_capture_service.dart';
import 'imu_visualization_page.dart';
import 'imu_batch_decode_page.dart';
import 'app_ui.dart';

class AndroidHomePage extends StatefulWidget {
  const AndroidHomePage({super.key, this.bluetooth, this.logs});
  final GnssBleService? bluetooth;
  final GgaLogService? logs;

  @override
  State<AndroidHomePage> createState() => _AndroidHomePageState();
}

class _AndroidHomePageState extends State<AndroidHomePage>
    with WidgetsBindingObserver {
  late final GnssBleService _bluetooth = widget.bluetooth ?? GnssBleService();
  late final GgaLogService _logs;
  final PhoneCaptureService _capture = PhoneCaptureService();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedIndex = 0;
  bool _importingFile = false;
  bool _captureVisited = false;
  bool _decodeVisited = false;

  @override
  void initState() {
    super.initState();
    _logs = widget.logs ?? GgaLogService(messages: _bluetooth.ggaStream);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_logs.flush());
  }

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  void _selectPage(int index) {
    if (index == 3 || index == 5) _capture.listen();
    if (index != 0) unawaited(_bluetooth.stopScan());
    setState(() {
      _selectedIndex = index;
      if (index == 3) _captureVisited = true;
      if (index == 4) _decodeVisited = true;
    });
    _scaffoldKey.currentState?.closeDrawer();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: mobileTheme(Theme.of(context)),
    child: Scaffold(
      key: _scaffoldKey,
      drawer: AppNavigationDrawer(
        selectedIndex: _selectedIndex,
        onSelected: _selectPage,
        keyPrefix: 'android-nav',
        destinations: [
          AppDestination(Icons.bluetooth, '设备连接', '发现与连接 GNSS'),
          AppDestination(Icons.map_outlined, '定位结果', '实时位置与轨迹回放'),
          AppDestination(Icons.folder_open_outlined, '日志存储', 'GGA 文件与分享'),
          AppDestination(Icons.sensors, '手机数据采集', 'GNSS · IMU · 磁场'),
          AppDestination(Icons.transform, 'IMU 批量解码', '原始数据转 CSV'),
          AppDestination(Icons.show_chart, 'IMU 数据可视化', '六轴 IMU · 磁场实时曲线'),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          DeviceConnectionPage(
            service: _bluetooth,
            onOpenDrawer: _openDrawer,
            onShowPositioning: () => _selectPage(1),
            importingFile: _importingFile,
            logs: _logs,
          ),
          MobilePositioningPage(
            mobileLayout: true,
            bluetooth: _bluetooth,
            onOpenDrawer: _openDrawer,
            onImportingChanged: (value) {
              if (mounted && value != _importingFile) {
                setState(() => _importingFile = value);
              }
            },
          ),
          GgaLogPage(
            service: _logs,
            onOpenDrawer: _openDrawer,
            active: _selectedIndex == 2,
          ),
          if (_captureVisited)
            PhoneCapturePage(
              onOpenDrawer: _openDrawer,
              service: _capture,
              onShowImu: () => _selectPage(5),
            )
          else
            const SizedBox.shrink(),
          if (_decodeVisited)
            ImuBatchDecodePage(onOpenDrawer: _openDrawer)
          else
            const SizedBox.shrink(),
          ImuVisualizationPage(
            dataStream: _capture.imuDataStream,
            sourceLabel: '手机传感器',
            emptyMessage: '在“手机数据采集”中同时检测加速度计与陀螺仪，勾选 IMU 并开始采集后查看曲线。磁场按独立频率显示。',
            onOpenDrawer: _openDrawer,
            onOpenSource: () => _selectPage(3),
            active: _selectedIndex == 5,
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.logs == null) _logs.dispose();
    if (widget.bluetooth == null) _bluetooth.dispose();
    _capture.dispose();
    super.dispose();
  }
}
