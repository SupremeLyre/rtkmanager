import 'package:flutter/material.dart';
import 'serial_debug_page.dart';
import 'rtk_config_page.dart';
import 'positioning_page.dart';
import 'satellite_page.dart';
import 'imu_batch_decode_page.dart';
import 'serial_imu_page.dart';
import 'app_ui.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
    _scaffoldKey.currentState?.closeDrawer();
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: AppNavigationDrawer(
        selectedIndex: _selectedIndex,
        onSelected: _onItemTapped,
        keyPrefix: 'desktop-nav',
        destinations: [
          AppDestination(Icons.usb, '串口调试助手', '连接设备与收发数据'),
          AppDestination(
            Icons.settings_input_antenna,
            'RTK 配置',
            'NTRIP 差分与数据转发',
          ),
          AppDestination(Icons.map_outlined, '定位结果', '实时位置与轨迹回放'),
          AppDestination(Icons.satellite_alt_outlined, '卫星信息', '信号强度与天空分布'),
          AppDestination(Icons.transform, 'IMU 批量解码', '原始数据转 CSV'),
          AppDestination(Icons.show_chart, 'IMU 数据可视化', '六轴 IMU · 磁场实时曲线'),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          SerialDebugPage(onOpenDrawer: _openDrawer),
          RtkConfigPage(onOpenDrawer: _openDrawer),
          MobilePositioningPage(onOpenDrawer: _openDrawer),
          SatellitePage(onOpenDrawer: _openDrawer),
          ImuBatchDecodePage(onOpenDrawer: _openDrawer),
          SerialImuPage(
            onOpenDrawer: _openDrawer,
            active: _selectedIndex == 5,
            onOpenSerial: () => setState(() => _selectedIndex = 0),
          ),
        ],
      ),
    );
  }
}
