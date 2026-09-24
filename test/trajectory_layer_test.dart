import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rtkmanager/trajectory_layer.dart';

TrajectoryPoint point(LatLng position, int index) => TrajectoryPoint(
  point: position,
  shape: TrajectoryShape.values[index % 3],
  size: [6.0, 5.0, 7.0][index % 3],
  color: [Colors.green, Colors.cyan, Colors.yellow][index % 3],
  borderColor: Colors.white,
  strokeWidth: 0.5,
  fillOpacity: 0.88,
);

void main() {
  for (final scenario in [
    (center: const LatLng(30.53, 114.35), zoom: 17.5, rotation: 0.0),
    (center: const LatLng(30.53, 114.35), zoom: 14.0, rotation: 43.0),
    (center: const LatLng(0, 179.999), zoom: 16.0, rotation: 24.0),
    (center: const LatLng(0, 180), zoom: 0.0, rotation: 0.0),
  ]) {
    testWidgets('preserves marker pixels at $scenario', (tester) async {
      await tester.binding.setSurfaceSize(const Size(540, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final points = [
        // Include overlapping samples to check opacity and stacking order.
        for (var i = 0; i < 21; i++)
          point(
            LatLng(
              scenario.center.latitude + (i % 7 - 3) * 0.0003,
              (scenario.center.longitude + (i % 7 - 3) * 0.0003 + 180) % 360 -
                  180,
            ),
            i,
          ),
        point(const LatLng(-70, -100), 1),
      ];
      Future<Uint8List> pixels(bool batched) async {
        final boundary = GlobalKey();
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: boundary,
              child: FlutterMap(
                key: ValueKey(batched),
                options: MapOptions(
                  initialCenter: scenario.center,
                  initialZoom: scenario.zoom,
                  initialRotation: scenario.rotation,
                ),
                children: [
                  if (batched)
                    TrajectoryLayer(points: points)
                  else
                    MarkerLayer(
                      markers: [
                        for (final p in points)
                          Marker(
                            point: p.point,
                            width: p.size,
                            height: p.size,
                            child: CustomPaint(
                              painter: _OriginalPointPainter(p),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return (await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return bytes!.buffer.asUint8List();
        }))!;
      }

      final original = await pixels(false);
      final batched = await pixels(true);
      // Atlas filtering can change edge antialiasing by a fraction of a pixel.
      // Compare only the painted region, so empty map pixels cannot hide a
      // missing/shifted symbol, wrong colour, or changed overlap order.
      var difference = 0;
      var paintedChannels = 0;
      var originalAlpha = 0;
      var batchedAlpha = 0;
      for (var i = 0; i < original.length; i += 4) {
        originalAlpha += original[i + 3];
        batchedAlpha += batched[i + 3];
        if (original[i + 3] == 0 && batched[i + 3] == 0) continue;
        for (var channel = 0; channel < 4; channel++) {
          difference += (batched[i + channel] - original[i + channel]).abs();
        }
        paintedChannels += 4;
      }
      expect(originalAlpha, greaterThan(0));
      expect(difference / paintedChannels, lessThan(12));
      expect(batchedAlpha / originalAlpha, closeTo(1, .08));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'large tracks retain samples without per-point layout or reprojection',
    (tester) async {
      final controller = MapController();
      final crs = _CountingMercator();
      addTearDown(crs.counter.dispose);
      final points = [
        for (var i = 0; i < 17000; i++)
          point(LatLng(30.53 + i * 0.000001, 114.35), i),
      ];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: FlutterMap(
            mapController: controller,
            options: MapOptions(
              crs: crs,
              initialCenter: const LatLng(30.53, 114.35),
              initialZoom: 17,
            ),
            children: [TrajectoryLayer(points: points)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TrajectoryLayer>(find.byType(TrajectoryLayer)).points,
        hasLength(17000),
      );
      expect(
        find.descendant(
          of: find.byType(TrajectoryLayer),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(TrajectoryLayer),
          matching: find.byType(Positioned),
        ),
        findsNothing,
      );
      final before = crs.projections;
      controller.move(const LatLng(30.531, 114.351), 17.5);
      controller.rotate(35);
      await tester.pump();
      expect(crs.projections - before, lessThan(100));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _CountingMercator extends Epsg3857 {
  final counter = ValueNotifier<int>(0);
  int get projections => counter.value;

  @override
  Offset latLngToOffset(LatLng latlng, double zoom) {
    counter.value++;
    return super.latLngToOffset(latlng, zoom);
  }
}

// Reference renderer from the previous per-widget implementation. Comparing
// pixels protects shapes, outlines, overlap order, rotation and world wrapping.
class _OriginalPointPainter extends CustomPainter {
  const _OriginalPointPainter(this.point);
  final TrajectoryPoint point;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = point.strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - point.strokeWidth,
      size.height - point.strokeWidth,
    );
    final path = ui.Path();
    switch (point.shape) {
      case TrajectoryShape.circle:
        path.addOval(rect);
      case TrajectoryShape.square:
        path.addRect(rect);
      case TrajectoryShape.cross:
        final centerX = size.width / 2;
        final centerY = size.height / 2;
        final halfBarWidth = size.shortestSide * 0.14;
        path
          ..moveTo(centerX - halfBarWidth, inset)
          ..lineTo(centerX + halfBarWidth, inset)
          ..lineTo(centerX + halfBarWidth, centerY - halfBarWidth)
          ..lineTo(size.width - inset, centerY - halfBarWidth)
          ..lineTo(size.width - inset, centerY + halfBarWidth)
          ..lineTo(centerX + halfBarWidth, centerY + halfBarWidth)
          ..lineTo(centerX + halfBarWidth, size.height - inset)
          ..lineTo(centerX - halfBarWidth, size.height - inset)
          ..lineTo(centerX - halfBarWidth, centerY + halfBarWidth)
          ..lineTo(inset, centerY + halfBarWidth)
          ..lineTo(inset, centerY - halfBarWidth)
          ..lineTo(centerX - halfBarWidth, centerY - halfBarWidth)
          ..close();
    }
    canvas.drawPath(
      path,
      Paint()..color = point.color.withValues(alpha: point.fillOpacity),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = point.borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = point.strokeWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _OriginalPointPainter oldDelegate) => true;
}
