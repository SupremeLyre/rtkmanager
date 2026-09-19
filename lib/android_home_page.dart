import 'dart:async';

import 'package:flutter/material.dart';

import 'device_connection_page.dart';
import 'gga_log_page.dart';
import 'gga_log_service.dart';
import 'gnss_ble_service.dart';
import 'positioning_page.dart';
import 'phone_capture_page.dart';
import 'imu_batch_decode_page.dart';
import 'mobile_ui.dart';

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
      drawer: SizedBox(
        width: MediaQuery.sizeOf(context).width < 360 ? 280 : 304,
        child: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                ),
                alignment: Alignment.bottomLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MobileIconTile(
                      Icons.satellite_alt,
                      active: true,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'RTK Manager',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 21,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'by SupremeLyre',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              for (final (index, icon, title, subtitle) in const [
                (0, Icons.bluetooth, '设备连接', '发现与连接 GNSS'),
                (1, Icons.map_outlined, '定位结果', '实时位置与轨迹回放'),
                (2, Icons.folder_open_outlined, '日志存储', 'GGA 文件与分享'),
                (3, Icons.sensors, '手机数据采集', 'GNSS · IMU · 磁场'),
                (4, Icons.transform, 'IMU 批量解码', '原始数据转 CSV'),
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    selectedTileColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: .6),
                    leading: Icon(icon),
                    title: Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      subtitle,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: _selectedIndex == index,
                    onTap: () => _selectPage(index),
                  ),
                ),
            ],
          ),
        ),
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
            ggaOnly: true,
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
            PhoneCapturePage(onOpenDrawer: _openDrawer)
          else
            const SizedBox.shrink(),
          if (_decodeVisited)
            ImuBatchDecodePage(onOpenDrawer: _openDrawer)
          else
            const SizedBox.shrink(),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.logs == null) _logs.dispose();
    if (widget.bluetooth == null) _bluetooth.dispose();
    super.dispose();
  }
}
