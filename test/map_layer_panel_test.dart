import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/map_layer_controller.dart';
import 'package:rtkmanager/map_layer_panel.dart';

void main() {
  testWidgets(
    'groups file layers and keeps independent visibility and locate',
    (tester) async {
      const receiver = r'C:\observations\receiver.log';
      const imu = r'C:\observations\imu.bin';
      final controller = MapLayerController()
        ..ensureLayer('live', label: '实时定位')
        ..ensureLayer('receiver-gga', label: 'GGA', sourcePath: receiver)
        ..ensureLayer('imu', label: 'IMU', sourcePath: imu)
        ..ensureLayer('receiver-ppp', label: 'PPPSOL', sourcePath: receiver)
        ..ensureLayer('imu-gga', label: 'GGA', sourcePath: imu);
      addTearDown(controller.dispose);
      String? located;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MapLayerPanel(
                controller: controller,
                pointCounts: const {
                  'receiver-gga': 12,
                  'receiver-ppp': 8,
                  'imu': 6,
                  'imu-gga': 4,
                },
                onLocate: (id) => located = id,
              ),
            ),
          ),
        ),
      );
      final receiverGroup = find.byKey(
        const ValueKey('layer-source-$receiver'),
      );
      final imuGroup = find.byKey(const ValueKey('layer-source-$imu'));
      expect(find.text(receiver), findsOneWidget);
      expect(find.text(imu), findsOneWidget);
      expect(
        find.descendant(of: receiverGroup, matching: find.text('GGA')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: receiverGroup, matching: find.text('PPPSOL')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: receiverGroup, matching: find.text('IMU')),
        findsNothing,
      );
      expect(
        find.descendant(of: imuGroup, matching: find.text('IMU')),
        findsOneWidget,
      );
      expect(find.text('实时定位'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('layer-visible-receiver-gga')),
      );
      await tester.pump();
      expect(controller.isVisible('receiver-gga'), isFalse);
      expect(controller.isVisible('imu-gga'), isTrue);
      expect(controller['receiver-gga']!.sourcePath, receiver);
      expect(
        find.descendant(of: receiverGroup, matching: find.text('GGA')),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('定位 PPPSOL（$receiver）'));
      expect(located, 'receiver-ppp');
      await tester.tap(find.text('全部隐藏'));
      await tester.pump();
      expect(controller.layers.every((layer) => !layer.visible), isTrue);
      expect(controller['imu']!.sourcePath, imu);
      expect(find.text(receiver), findsOneWidget);
      expect(find.text(imu), findsOneWidget);
      await tester.tap(find.text('全部显示'));
      await tester.pump();
      expect(controller.layers.every((layer) => layer.visible), isTrue);
      expect(controller['receiver-ppp']!.sourcePath, receiver);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('removes only the requested file group', (tester) async {
    const receiver = r'C:\observations\receiver.log';
    const imu = r'C:\observations\imu.bin';
    final controller = MapLayerController()
      ..ensureLayer('live', label: '实时定位')
      ..ensureLayer('receiver-gga', label: 'GGA', sourcePath: receiver)
      ..ensureLayer('receiver-ppp', label: 'PPPSOL', sourcePath: receiver)
      ..ensureLayer('imu', label: 'IMU', sourcePath: imu);
    addTearDown(controller.dispose);
    final removed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MapLayerPanel(
              controller: controller,
              onRemoveFile: (path) {
                removed.add(path);
                for (final layer in controller.layers.toList()) {
                  if (layer.sourcePath == path) {
                    controller.removeLayer(layer.id);
                  }
                }
              },
            ),
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('layer-remove-file-$receiver')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('layer-remove-file-$imu')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('layer-remove-file-null')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('layer-remove-file-$receiver')));
    await tester.pump();
    expect(removed, [receiver]);
    expect(find.text(receiver), findsNothing);
    expect(controller['receiver-gga'], isNull);
    expect(controller['receiver-ppp'], isNull);
    expect(find.text(imu), findsOneWidget);
    expect(find.text('实时定位'), findsOneWidget);
    expect(controller['imu'], isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full long paths wrap on small screens and with scaled text', (
    tester,
  ) async {
    final source = 'C:\\${'longdirectory' * 12}\\receiver.log';
    final controller = MapLayerController()
      ..ensureLayer('file-gga', label: 'GGA', sourcePath: source);
    addTearDown(controller.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final brightness in [Brightness.light, Brightness.dark]) {
      for (final size in [
        const Size(375, 720),
        const Size(720, 375),
        const Size(1000, 760),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(3),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: MapLayerPanel(
                    controller: controller,
                    pointCounts: const {'file-gga': 10},
                    onLocate: (_) {},
                    onRemoveFile: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(source), findsOneWidget);
        expect(tester.getSize(find.text(source)).height, greaterThan(60));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
