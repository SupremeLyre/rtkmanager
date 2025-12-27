import 'package:flutter/material.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'home_page.dart';

void main() {
  runApp(const MyApp());

  doWhenWindowReady(() {
    final win = appWindow;
    const initialSize = Size(800, 480);
    win.minSize = const Size(400, 300);
    win.size = initialSize;
    win.alignment = Alignment.center;
    win.title = "RTK Manager";
    win.show();
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RTK Manager',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
        fontFamily: 'SourceHanSansHWSC',
      ),
      home: const CustomWindowFrame(child: HomePage()),
    );
  }
}

class CustomWindowFrame extends StatelessWidget {
  final Widget child;

  const CustomWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: WindowBorder(
        color: Colors.transparent,
        width: 0,
        child: Column(
          children: [
            const WindowTitleBar(),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28, // 尽量压低高度
      color: const Color(0xFFE0E0E0), // 浅灰色背景，类似 macOS
      child: Row(
        children: [
          const SizedBox(width: 8),
          const WindowButtons(),
          Expanded(
            child: MoveWindow(
              child: const Center(
                child: Text(
                  "RTK Manager",
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _buildCircleButton(
          color: const Color(0xFFFF5F56), // Red - Close
          onTap: () => appWindow.close(),
        ),
        const SizedBox(width: 8),
        _buildCircleButton(
          color: const Color(0xFFFFBD2E), // Yellow - Minimize
          onTap: () => appWindow.minimize(),
        ),
        const SizedBox(width: 8),
        _buildCircleButton(
          color: const Color(0xFF27C93F), // Green - Maximize/Restore
          onTap: () => appWindow.maximizeOrRestore(),
        ),
      ],
    );
  }

  Widget _buildCircleButton({required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
