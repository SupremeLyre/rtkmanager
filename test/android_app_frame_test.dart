import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/android_app_frame.dart';

void main() {
  for (final (size, insets) in [
    (const Size(360, 740), const FakeViewPadding(top: 44, bottom: 24)),
    (
      const Size(740, 360),
      const FakeViewPadding(left: 44, right: 24, top: 24, bottom: 24),
    ),
  ]) {
    testWidgets('system insets are painted and toolbar is unobscured at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = insets;
      tester.view.viewPadding = insets;
      // The app stays light when the phone uses its dark system theme.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      );
      final boundaryKey = GlobalKey();
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: boundaryKey,
            child: AndroidAppFrame(
              child: Scaffold(
                appBar: AppBar(
                  toolbarHeight: 48,
                  title: const Text('定位结果'),
                  leading: IconButton(
                    tooltip: '打开导航',
                    onPressed: () => tapped = true,
                    icon: const Icon(Icons.menu),
                  ),
                ),
                body: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final appBar = tester.getRect(find.byType(AppBar));
      expect(appBar.top, insets.top);
      expect(appBar.left, insets.left);
      expect(appBar.right, size.width - insets.right);
      expect(
        appBar.height,
        48,
      ); // Insets are consumed once, not added again by AppBar.
      expect(
        tester.getRect(find.text('定位结果')).top,
        greaterThanOrEqualTo(insets.top),
      );
      await tester.tap(find.byTooltip('打开导航'));
      expect(tapped, isTrue);
      await tester.pumpAndSettle();

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundaryKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final color = theme.colorScheme.surface.toARGB32();
        for (final (x, y) in [
          (1, 1),
          (1, image.height - 1),
          (image.width - 1, image.height - 1),
        ]) {
          final offset = (y * image.width + x) * 4;
          expect(
            [for (var i = 0; i < 4; i++) pixels.getUint8(offset + i)],
            [(color >> 16) & 255, (color >> 8) & 255, color & 255, 255],
            reason:
                'Safe insets must have the page background, not unpainted black pixels',
          );
        }
        image.dispose();
      });
      expect(
        SystemChrome.latestStyle?.statusBarIconBrightness,
        Brightness.dark,
      );
      expect(
        SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
        Brightness.dark,
      );
      expect(
        SystemChrome.latestStyle?.systemStatusBarContrastEnforced,
        isFalse,
      );
      expect(
        SystemChrome.latestStyle?.systemNavigationBarContrastEnforced,
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
