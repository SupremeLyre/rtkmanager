import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

enum TrajectoryShape { circle, square, cross }

/// A non-interactive observation. Original samples and their drawing order are
/// retained; interactive device pins belong in a separate MarkerLayer.
@immutable
class TrajectoryPoint {
  const TrajectoryPoint({
    required this.point,
    required this.shape,
    required this.size,
    required this.color,
    required this.borderColor,
    required this.strokeWidth,
    required this.fillOpacity,
  });

  final LatLng point;
  final TrajectoryShape shape;
  final double size;
  final Color color;
  final Color borderColor;
  final double strokeWidth;
  final double fillOpacity;

  _Style get _style => (
    shape: shape,
    size: size,
    color: color.withValues(alpha: fillOpacity),
    border: borderColor,
    stroke: strokeWidth,
  );
}

typedef _Style = ({
  TrajectoryShape shape,
  double size,
  Color color,
  Color border,
  double stroke,
});

/// Draws trajectory samples on one canvas instead of laying out a widget for
/// every visible sample on every map gesture.
class TrajectoryLayer extends StatefulWidget {
  const TrajectoryLayer({super.key, required this.points});

  /// Supply a new list when observations, styles, or layer visibility change.
  final List<TrajectoryPoint> points;

  @override
  State<TrajectoryLayer> createState() => _TrajectoryLayerState();
}

class _TrajectoryLayerState extends State<TrajectoryLayer> {
  _SymbolAtlas? _atlas;
  List<TrajectoryPoint>? _source;
  Crs? _crs;
  double? _projectionZoom;
  List<({Offset position, double halfSize, Rect sprite})> _projected = [];
  final _buffers = _AtlasBuffers();

  void _prepare(MapCamera camera, double pixelRatio) {
    // Web Mercator scales linearly from zoom zero. Cache the expensive
    // geographic projection across both pan and pinch gestures. Other CRSs
    // retain their exact projection at the current zoom.
    final zoom = camera.crs is Epsg3857 ? 0.0 : camera.zoom;
    if (identical(_source, widget.points) &&
        _crs == camera.crs &&
        _projectionZoom == zoom &&
        _atlas?.pixelRatio == pixelRatio) {
      return;
    }
    _source = widget.points;
    _crs = camera.crs;
    _projectionZoom = zoom;
    final used = {for (final point in widget.points) point._style};
    if (_atlas?.pixelRatio != pixelRatio ||
        !setEquals(used, _atlas?.rects.keys.toSet())) {
      _atlas?.image.dispose();
      _atlas = _SymbolAtlas(used, pixelRatio);
    }
    _projected = [
      for (final point in widget.points)
        (
          position: camera.projectAtZoom(point.point, zoom),
          halfSize: point.size / 2,
          sprite: _atlas!.rects[point._style]!,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    _prepare(camera, View.of(context).devicePixelRatio);
    return MobileLayerTransformer(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            size: camera.size,
            painter: _TrajectoryPainter(
              points: _projected,
              camera: camera,
              scale: camera.getZoomScale(camera.zoom, _projectionZoom!),
              atlas: _atlas!,
              buffers: _buffers,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _atlas?.image.dispose();
    super.dispose();
  }
}

class _TrajectoryPainter extends CustomPainter {
  const _TrajectoryPainter({
    required this.points,
    required this.camera,
    required this.scale,
    required this.atlas,
    required this.buffers,
  });

  final List<({Offset position, double halfSize, Rect sprite})> points;
  final MapCamera camera;
  final double scale;
  final _SymbolAtlas atlas;
  final _AtlasBuffers buffers;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = camera.pixelOrigin;
    final worldWidth = camera.getWorldWidthAtZoom();
    canvas.clipRect(Offset.zero & size);
    var count = 0;
    // Reuse packed buffers, including when a viewport shows repeated worlds.
    buffers.ensureCapacity(points.length * 4);
    for (final point in points) {
      final x = point.position.dx * scale - origin.dx;
      final y = point.position.dy * scale - origin.dy;
      final radius = point.halfSize;
      if (y < -radius || y > size.height + radius) continue;

      // Repeat visible worlds just as MarkerLayer does, including dateline
      // crossing and low zoom levels. Cull before issuing any draw commands.
      final first = worldWidth == 0 ? 0 : ((-radius - x) / worldWidth).ceil();
      final last = worldWidth == 0
          ? 0
          : ((size.width + radius - x) / worldWidth).floor();
      for (var world = first; world <= last; world++) {
        final localX = x + world * worldWidth;
        if (localX < -radius || localX > size.width + radius) continue;
        buffers.ensureCapacity(count + 4);
        final rect = point.sprite;
        buffers.transforms[count] = atlas.inverseScale;
        buffers.transforms[count + 1] = 0;
        buffers.transforms[count + 2] = localX - radius - atlas.padding;
        buffers.transforms[count + 3] = y - radius - atlas.padding;
        buffers.rects[count] = rect.left;
        buffers.rects[count + 1] = rect.top;
        buffers.rects[count + 2] = rect.right;
        buffers.rects[count + 3] = rect.bottom;
        count += 4;
      }
    }
    if (count == 0) return;
    // One textured batch avoids thousands of path tessellations on the raster
    // thread. Input order is preserved, including translucent overlapping fixes.
    canvas.drawRawAtlas(
      atlas.image,
      Float32List.sublistView(buffers.transforms, 0, count),
      Float32List.sublistView(buffers.rects, 0, count),
      null,
      null,
      null,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant _TrajectoryPainter oldDelegate) =>
      !identical(points, oldDelegate.points) ||
      atlas != oldDelegate.atlas ||
      camera != oldDelegate.camera ||
      scale != oldDelegate.scale;
}

class _AtlasBuffers {
  Float32List transforms = Float32List(0);
  Float32List rects = Float32List(0);

  void ensureCapacity(int needed) {
    if (transforms.length >= needed) return;
    final capacity = math.max(needed, math.max(64, transforms.length * 2));
    transforms = Float32List(capacity)..setAll(0, transforms);
    rects = Float32List(capacity)..setAll(0, rects);
  }
}

class _SymbolAtlas {
  _SymbolAtlas(Set<_Style> styles, this.pixelRatio) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    var x = 0;
    var y = 0;
    var rowHeight = 0;
    var width = 1;
    for (final style in styles) {
      final extent = (style.size / inverseScale).ceil() + 4;
      if (x + extent > 1024 && x != 0) {
        x = 0;
        y += rowHeight;
        rowHeight = 0;
      }
      rects[style] = Rect.fromLTWH(
        x.toDouble(),
        y.toDouble(),
        extent.toDouble(),
        extent.toDouble(),
      );
      canvas.save();
      canvas.translate(x + 2.0, y + 2.0);
      canvas.scale(1 / inverseScale);
      _paintPoint(canvas, style);
      canvas.restore();
      x += extent;
      width = math.max(width, x);
      rowHeight = math.max(rowHeight, extent);
    }
    final picture = recorder.endRecording();
    image = picture.toImageSync(width, math.max(1, y + rowHeight));
    picture.dispose();
  }

  final double pixelRatio;
  // Supersample small symbols so outlines stay crisp on dense displays. A
  // transparent gutter prevents neighbouring symbols bleeding when filtered.
  double get inverseScale => 1 / math.max(2, pixelRatio * 2);
  double get padding => 2 * inverseScale;
  final rects = <_Style, Rect>{};
  late final ui.Image image;
}

/// Uses the same symbols as the trajectory canvas for the map legend.
class TrajectorySymbolPainter extends CustomPainter {
  const TrajectorySymbolPainter({
    required this.shape,
    required this.color,
    required this.borderColor,
    this.strokeWidth = 0.8,
    this.fillOpacity = 0.88,
  });

  final TrajectoryShape shape;
  final Color color;
  final Color borderColor;
  final double strokeWidth;
  final double fillOpacity;

  @override
  void paint(Canvas canvas, Size size) => _paintPoint(canvas, (
    shape: shape,
    size: size.shortestSide,
    color: color.withValues(alpha: fillOpacity),
    border: borderColor,
    stroke: strokeWidth,
  ));

  @override
  bool shouldRepaint(covariant TrajectorySymbolPainter oldDelegate) =>
      shape != oldDelegate.shape ||
      color != oldDelegate.color ||
      borderColor != oldDelegate.borderColor ||
      strokeWidth != oldDelegate.strokeWidth ||
      fillOpacity != oldDelegate.fillOpacity;
}

void _paintPoint(Canvas canvas, _Style style) {
  final inset = style.stroke / 2;
  final extent = style.size;
  final rect = Rect.fromLTWH(
    inset,
    inset,
    extent - style.stroke,
    extent - style.stroke,
  );
  final path = ui.Path();
  switch (style.shape) {
    case TrajectoryShape.circle:
      path.addOval(rect);
    case TrajectoryShape.square:
      path.addRect(rect);
    case TrajectoryShape.cross:
      final center = extent / 2;
      final halfBar = extent * 0.14;
      path
        ..moveTo(center - halfBar, inset)
        ..lineTo(center + halfBar, inset)
        ..lineTo(center + halfBar, center - halfBar)
        ..lineTo(extent - inset, center - halfBar)
        ..lineTo(extent - inset, center + halfBar)
        ..lineTo(center + halfBar, center + halfBar)
        ..lineTo(center + halfBar, extent - inset)
        ..lineTo(center - halfBar, extent - inset)
        ..lineTo(center - halfBar, center + halfBar)
        ..lineTo(inset, center + halfBar)
        ..lineTo(inset, center - halfBar)
        ..lineTo(center - halfBar, center - halfBar)
        ..close();
  }
  canvas.drawPath(path, Paint()..color = style.color);
  if (style.stroke > 0 && style.border.a > 0) {
    canvas.drawPath(
      path,
      Paint()
        ..color = style.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = style.stroke,
    );
  }
}
