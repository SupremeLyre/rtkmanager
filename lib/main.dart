import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 在支持的桌面平台上初始化窗口管理器
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      await windowManager.ensureInitialized();
      const desiredSize = Size(1000, 720);
      Size initialSize = const Size(800, 480);
      try {
        final display = await screenRetriever.getPrimaryDisplay();
        final availableSize = display.visibleSize ?? display.size;
        initialSize = Size(
          availableSize.width < desiredSize.width
              ? availableSize.width
              : desiredSize.width,
          availableSize.height < desiredSize.height
              ? availableSize.height
              : desiredSize.height,
        );
      } catch (_) {
        // 无法读取屏幕工作区时维持原有启动尺寸。
      }

      final WindowOptions windowOptions = WindowOptions(
        size: initialSize,
        minimumSize: Size(400, 300),
        center: true,
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden, // 隐藏原生系统标题栏
      );
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (_) {
      // 树莓派 (flutter-pi) 环境下没有对应原生插件实现，会抛出 MissingPluginException。
      // 捕获并忽略，即可保证在树莓派上正常运行无窗口边缘的全屏界面。
    }
  }

  runApp(const MyApp());
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
      body: Column(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque, // 铺满整个标题栏区域的点击/拖拽触发范围
            onPanStart: (details) {
              try {
                windowManager.startDragging(); // 原生窗口拖拽API
              } catch (_) {}
            },
            onDoubleTap: () async {
              try {
                bool isMaximized = await windowManager.isMaximized();
                if (isMaximized) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              } catch (_) {}
            },
            child: const WindowTitleBar(),
          ),
          Expanded(child: child),
        ],
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
          const Expanded(
            child: Center(
              child: Text(
                "RTK Manager",
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
          ),
          // 为了让标题居中，右边加一个占位
          const SizedBox(width: 60),
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
          onTap: () async {
            try {
              await windowManager.close(); // 尝试原生退出
            } catch (_) {
              SystemNavigator.pop(); // 失败（如树莓派端）降级为 Flutter 原生退出
            }
          },
        ),
        const SizedBox(width: 8),
        _CircleButton(
          color: const Color(0xFFFFBD2E), // Yellow - Minimize
          icon: Icons.remove,
          onTap: () async {
            try {
              await windowManager.minimize(); // 尝试原生最小化
            } catch (_) {}
          },
        ),
        const SizedBox(width: 8),
        _CircleButton(
          color: const Color(0xFF27C93F), // Green - Maximize
          customIcon: CustomPaint(
            size: const Size(8, 8),
            painter: _MacMaximizeIconPainter(
              color: const Color(0xFF4D0000).withValues(alpha: 0.6),
            ),
          ),
          onTap: () async {
            try {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            } catch (_) {}
          },
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

    final path1 = Path()
      ..moveTo(0, 0)
      ..lineTo(4, 0)
      ..lineTo(0, 4)
      ..close();

    final path2 = Path()
      ..moveTo(size.width, size.height)
      ..lineTo(size.width - 4, size.height)
      ..lineTo(size.width, size.height - 4)
      ..close();

    canvas.drawPath(path1, paint);
    canvas.drawPath(path2, paint);
  }

  @override
  bool shouldRepaint(covariant _MacMaximizeIconPainter oldDelegate) =>
      oldDelegate.color != color;
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
