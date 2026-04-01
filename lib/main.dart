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
        _CircleButton(
          color: const Color(0xFFFF5F56), // Red - Close
          icon: Icons.close,
          onTap: () => appWindow.close(),
        ),
        const SizedBox(width: 8),
        _CircleButton(
          color: const Color(0xFFFFBD2E), // Yellow - Minimize
          icon: Icons.remove,
          onTap: () => appWindow.minimize(),
        ),
        const SizedBox(width: 8),
        _CircleButton(
          color: const Color(0xFF27C93F), // Green - Maximize/Restore
          customIcon: CustomPaint(
            size: const Size(8, 8),
            painter: _MacMaximizeIconPainter(
              color: const Color(0xFF4D0000).withValues(alpha: 0.6),
            ),
          ),
          onTap: () => appWindow.maximizeOrRestore(),
        ),
      ],
    );
  }
}

class _MacMaximizeIconPainter extends CustomPainter {
  final Color color;

  _MacMaximizeIconPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // 左上角三角形
    final path1 = Path()
      ..moveTo(0, 0)
      ..lineTo(4, 0)
      ..lineTo(0, 4)
      ..close();

    // 右下角三角形
    final path2 = Path()
      ..moveTo(size.width, size.height)
      ..lineTo(size.width - 4, size.height)
      ..lineTo(size.width, size.height - 4)
      ..close();

    canvas.drawPath(path1, paint);
    canvas.drawPath(path2, paint);
  }

  @override
  bool shouldRepaint(covariant _MacMaximizeIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _CircleButton extends StatefulWidget {
  final Color color;
  final IconData? icon;
  final Widget? customIcon;
  final VoidCallback onTap;

  const _CircleButton({
    required this.color,
    this.icon,
    this.customIcon,
    required this.onTap,
  });

  @override
  State<_CircleButton> createState() => _CircleButtonState();
}

class _CircleButtonState extends State<_CircleButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: _isHovering
              ? (widget.customIcon ??
                    (widget.icon != null
                        ? Icon(
                            widget.icon,
                            size: 9,
                            color: const Color(
                              0xFF4D0000,
                            ).withValues(alpha: 0.6),
                          )
                        : null))
              : null,
        ),
      ),
    );
  }
}
