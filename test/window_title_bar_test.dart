import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/window_title_bar.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  var maximized = false;
  var active = true;
  late List<String> calls;
  final preview = GlobalKey();
  Finder button(String name) => find.byKey(ValueKey('window-$name'));
  Finder glyph(String name) => find.byKey(ValueKey('window-$name-glyph'));
  Color discColor(WidgetTester tester, String name) =>
      (tester
                  .widget<Container>(find.byKey(ValueKey('window-$name-disc')))
                  .decoration!
              as BoxDecoration)
          .color!;

  Future<void> mount(WidgetTester tester, {bool dark = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: dark ? Brightness.dark : Brightness.light,
          fontFamily: 'SourceHanSansHWSC',
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 560,
              child: RepaintBoundary(
                key: preview,
                child: const WindowTitleBar(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.runAsync(() async {
      final boundary =
          preview.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/ui-previews/window-controls-$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  setUpAll(() async {
    await (FontLoader(
      'SourceHanSansHWSC',
    )..addFont(rootBundle.load('fonts/SourceHanSansHWSC-Regular.otf'))).load();
  });

  setUp(() {
    calls = [];
    maximized = false;
    active = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'isFocused':
              return active;
            case 'isMaximized':
              return maximized;
            case 'isFullScreen':
              return false;
            case 'maximize':
              maximized = true;
            case 'unmaximize':
              maximized = false;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'Traffic lights reveal only the hovered button and retain pressed and inactive states',
    (tester) async {
      await mount(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 100));
      addTearDown(mouse.removePointer);
      for (final name in ['close', 'minimize', 'expand']) {
        expect(glyph(name), findsNothing);
        expect(tester.getSize(button(name)), const Size(20, 28));
      }
      expect(
        tester.getCenter(button('minimize')).dx -
            tester.getCenter(button('close')).dx,
        20,
      );
      await capture(tester, 'normal');

      for (final hovered in ['expand', 'minimize', 'close']) {
        await mouse.moveTo(tester.getCenter(button(hovered)));
        await tester.pump();
        for (final name in ['close', 'minimize', 'expand']) {
          expect(glyph(name), name == hovered ? findsOneWidget : findsNothing);
        }
      }
      await capture(tester, 'hover');
      final idleRed = discColor(tester, 'close');
      await mouse.down(tester.getCenter(button('close')));
      await tester.pump(const Duration(milliseconds: 120));
      expect(discColor(tester, 'close'), isNot(idleRed));
      await capture(tester, 'pressed');
      await mouse.moveTo(const Offset(400, 100));
      await mouse.up();
      await tester.pump();
      for (final name in ['close', 'minimize', 'expand']) {
        expect(glyph(name), findsNothing);
      }
      expect(
        calls,
        isNot(contains('close')),
        reason: 'Dragging away cancels a close',
      );

      active = false;
      for (final listener in windowManager.listeners) {
        listener.onWindowBlur();
      }
      await tester.pump();
      expect(discColor(tester, 'close'), discColor(tester, 'minimize'));
      expect(discColor(tester, 'close'), discColor(tester, 'expand'));
      await capture(tester, 'inactive');
      await mouse.moveTo(tester.getCenter(button('minimize')));
      await tester.pump();
      expect(discColor(tester, 'close'), idleRed);
      expect(glyph('minimize'), findsOneWidget);
      expect(glyph('close'), findsNothing);
      expect(glyph('expand'), findsNothing);
      await mouse.moveTo(const Offset(400, 100));
      active = true;
      for (final listener in windowManager.listeners) {
        listener.onWindowFocus();
      }
      await tester.pump();
      expect(discColor(tester, 'close'), idleRed);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Window actions stay close, minimize and maximize even with Alt',
    (tester) async {
      await mount(tester);
      calls.clear();
      await tester.tap(button('minimize'));
      await tester.pumpAndSettle();
      await tester.tap(button('close'));
      await tester.pumpAndSettle();
      expect(calls, ['minimize', 'close']);

      await tester.tap(button('expand'));
      await tester.pumpAndSettle();
      expect(maximized, isTrue);
      expect(find.byTooltip('还原窗口'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tap(button('expand'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(maximized, isFalse);
      expect(find.byTooltip('最大化'), findsOneWidget);
      expect(calls, isNot(contains('setFullScreen')));

      final title = find.text('RTK Manager');
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(maximized, isTrue);
      await tester.drag(
        find.byKey(const ValueKey('window-drag-area')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();
      expect(calls, contains('startDragging'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Dark controls keep keyboard labels and track external restore', (
    tester,
  ) async {
    maximized = true;
    await mount(tester, dark: true);
    final semantics = tester.ensureSemantics();
    expect(find.byTooltip('还原窗口'), findsOneWidget);
    expect(tester.getSemantics(button('close')).label, '关闭窗口');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(glyph('close'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, contains('close'));

    maximized = false;
    for (final listener in windowManager.listeners) {
      listener.onWindowUnmaximize();
    }
    await tester.pump();
    expect(find.byTooltip('最大化'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 100));
    await mouse.moveTo(tester.getCenter(button('expand')));
    await tester.pump();
    await capture(tester, 'dark-hover');
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    expect(windowManager.listeners.whereType<State<WindowTitleBar>>(), isEmpty);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
