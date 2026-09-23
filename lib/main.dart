import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'home_page.dart';
import 'android_home_page.dart';
import 'android_app_frame.dart';
import 'app_ui.dart';
import 'window_title_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

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
      theme: mobileTheme(
        ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
          fontFamily: 'SourceHanSansHWSC',
        ),
      ),
      home: CustomWindowFrame(
        child: Platform.isAndroid ? const AndroidHomePage() : const HomePage(),
      ),
    );
  }
}

class CustomWindowFrame extends StatelessWidget {
  final Widget child;

  const CustomWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) {
      return AndroidAppFrame(child: child);
    }
    if (Platform.isIOS) {
      return SafeArea(child: child);
    }

    return Scaffold(
      body: Column(
        children: [
          const WindowTitleBar(),
          Expanded(child: child),
        ],
      ),
    );
  }
}
