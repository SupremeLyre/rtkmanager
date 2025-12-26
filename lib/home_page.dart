import 'package:flutter/material.dart';
import 'serial_debug_page.dart';
import 'rtk_config_page.dart';

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
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text(
                'RTK Manager\r\nby SupremeLyre',
                style: TextStyle(color: Colors.white, fontSize: 24),
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
          ],
        ),
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          SerialDebugPage(onOpenDrawer: _openDrawer),
          RtkConfigPage(onOpenDrawer: _openDrawer),
        ],
      ),
    );
  }
}
