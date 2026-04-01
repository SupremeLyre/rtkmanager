import 'package:flutter/material.dart';
import 'serial_debug_page.dart';
import 'rtk_config_page.dart';
import 'positioning_page.dart';
import 'satellite_page.dart';

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
    Navigator.pop(context); // Close the drawer
  }

  void _openDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: SizedBox(
        width: 200,
        child: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Container(
                height: 80,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                decoration: const BoxDecoration(color: Colors.blue),
                alignment: Alignment.bottomLeft,
                child: const Text(
                  'RTK Manager\r\nby SupremeLyre',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.developer_board),
                title: const Text('串口调试助手'),
                selected: _selectedIndex == 0,
                onTap: () => _onItemTapped(0),
              ),
              ListTile(
                leading: const Icon(Icons.settings),
                title: const Text('RTK 配置'),
                selected: _selectedIndex == 1,
                onTap: () => _onItemTapped(1),
              ),
              ListTile(
                leading: const Icon(Icons.map),
                title: const Text('定位结果'),
                selected: _selectedIndex == 2,
                onTap: () => _onItemTapped(2),
              ),
              ListTile(
                leading: const Icon(Icons.satellite),
                title: const Text('卫星信息'),
                selected: _selectedIndex == 3,
                onTap: () => _onItemTapped(3),
              ),
            ],
          ),
        ),
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          SerialDebugPage(onOpenDrawer: _openDrawer),
          RtkConfigPage(onOpenDrawer: _openDrawer),
          MobilePositioningPage(onOpenDrawer: _openDrawer),
          SatellitePage(onOpenDrawer: _openDrawer),
        ],
      ),
    );
  }
}
