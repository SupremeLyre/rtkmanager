import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'accuracy_evaluation.dart';
import 'position_data.dart';

enum AccuracyChartKind { position, velocity, attitude }

String accuracyUtcLabel(DateTime time) => time
    .toUtc()
    .toIso8601String()
    .replaceFirst('T', ' ')
    .replaceFirst('Z', ' UTC');

ErrorVector accuracyVector(
  EpochError record,
  AccuracyChartKind kind,
  bool corrected,
) => switch (kind) {
  AccuracyChartKind.position =>
    corrected ? record.correctedPosition : record.rawPosition,
  AccuracyChartKind.velocity =>
    corrected ? record.correctedVelocity : record.rawVelocity,
  AccuracyChartKind.attitude =>
    corrected ? record.correctedAttitude : record.rawAttitude,
};

class AccuracyTimeChart extends StatefulWidget {
  const AccuracyTimeChart({
    super.key,
    required this.records,
    required this.kind,
    required this.corrected,
    required this.selectedPoint,
    required this.onSelected,
    this.height = 240,
  });

  final List<EpochError> records;
  final AccuracyChartKind kind;
  final bool corrected;
  final PositionHistoryPoint? selectedPoint;
  final ValueChanged<EpochError> onSelected;
  final double height;

  @override
  State<AccuracyTimeChart> createState() => _AccuracyTimeChartState();
}

class _AccuracyTimeChartState extends State<AccuracyTimeChart> {
  EpochError? _hovered;
  final _cache = _ChartCache();
  final Map<PositionHistoryPoint, EpochError> _recordsByPoint = Map.identity();

  @override
  void initState() {
    super.initState();
    _indexRecords();
  }

  @override
  void didUpdateWidget(AccuracyTimeChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.records, widget.records)) {
      _hovered = null;
      _indexRecords();
    }
  }

  void _indexRecords() {
    _recordsByPoint
      ..clear()
      ..addEntries(
        widget.records.map((record) => MapEntry(record.point, record)),
      );
  }

  @override
  void dispose() {
    _cache.picture?.dispose();
    super.dispose();
  }

  EpochError _nearest(double x, double width) {
    final records = widget.records;
    final left = records.first.utcTime.microsecondsSinceEpoch;
    final right = records.last.utcTime.microsecondsSinceEpoch;
    final rect =
        _cache.plotRect ?? Rect.fromLTWH(58, 22, math.max(1, width - 74), 160);
    final fraction = ((x - rect.left) / rect.width).clamp(0.0, 1.0);
    final target = left + (right - left) * fraction;
    var low = 0;
    var high = records.length - 1;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (records[middle].utcTime.microsecondsSinceEpoch < target) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low > 0 &&
        (records[low - 1].utcTime.microsecondsSinceEpoch - target).abs() <=
            (records[low].utcTime.microsecondsSinceEpoch - target).abs()) {
      low--;
    }
    return records[low];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.records.isEmpty) return const Text('没有匹配历元。');
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
    final dark = theme.brightness == Brightness.dark;
    final lineColors = [
      colors.primary,
      dark ? Colors.cyan.shade300 : Colors.cyan.shade800,
      dark ? Colors.orange.shade300 : Colors.deepOrange.shade600,
      colors.onSurfaceVariant,
    ];
    final labels = widget.kind == AccuracyChartKind.attitude
        ? ['Roll', 'Pitch', 'Heading']
        : ['E', 'N', 'U', if (widget.kind == AccuracyChartKind.position) '水平'];
    final unit = switch (widget.kind) {
      AccuracyChartKind.position => 'm',
      AccuracyChartKind.velocity => 'm/s',
      AccuracyChartKind.attitude => '°',
    };
    final selected = _hovered ?? _recordsByPoint[widget.selectedPoint];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [
            for (var axis = 0; axis < labels.length; axis++)
              Semantics(
                label: '${labels[axis]}误差',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 16,
                      height: 3,
                      decoration: BoxDecoration(
                        color: lineColors[axis],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(labels[axis], style: theme.textTheme.labelMedium),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) => Semantics(
            label: '误差时序图，点击选择历元',
            child: MouseRegion(
              cursor: SystemMouseCursors.precise,
              onHover: (event) {
                final nearest = _nearest(
                  event.localPosition.dx,
                  constraints.maxWidth,
                );
                if (!identical(_hovered, nearest)) {
                  setState(() => _hovered = nearest);
                }
              },
              onExit: (_) => setState(() => _hovered = null),
              child: GestureDetector(
                key: ValueKey('accuracy-chart-${widget.kind.name}'),
                behavior: HitTestBehavior.opaque,
                onTapDown: (event) => widget.onSelected(
                  _nearest(event.localPosition.dx, constraints.maxWidth),
                ),
                child: SizedBox(
                  height: widget.height + math.max(0, textScale - 1) * 50,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: _AccuracyChartPainter(
                              cache: _cache,
                              records: widget.records,
                              kind: widget.kind,
                              corrected: widget.corrected,
                              selected: selected,
                              colors: lineColors,
                              foreground: colors.onSurfaceVariant,
                              gridColor: colors.outlineVariant,
                              background: colors.surface,
                              unit: unit,
                              textScale: textScale,
                              fontFamily: theme.textTheme.bodySmall?.fontFamily,
                            ),
                          ),
                        ),
                      ),
                      if (_hovered != null)
                        Positioned(
                          top: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: _hoverDetails(
                              context,
                              labels,
                              lineColors,
                              unit,
                              constraints.maxWidth,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Tooltip(
            message: '起始 ${accuracyUtcLabel(widget.records.first.utcTime)}',
            child: Text(
              '相对时间 / s',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _hoverDetails(
    BuildContext context,
    List<String> labels,
    List<Color> lineColors,
    String unit,
    double width,
  ) {
    final theme = Theme.of(context);
    final vector = accuracyVector(_hovered!, widget.kind, widget.corrected);
    return Container(
      constraints: BoxConstraints(maxWidth: math.min(width, 300)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: .06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            accuracyUtcLabel(_hovered!.utcTime),
            style: theme.textTheme.labelSmall,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              for (var axis = 0; axis < labels.length; axis++)
                Text(
                  '${labels[axis]} ${_format(_component(vector, axis))}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: lineColors[axis],
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              Text(unit, style: theme.textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}

double? _component(ErrorVector vector, int axis) => switch (axis) {
  0 => vector.x,
  1 => vector.y,
  2 => vector.z,
  _ => vector.horizontal,
};

String _format(double? value) => value?.toStringAsFixed(3) ?? '—';

class _ChartCache {
  ui.Picture? picture;
  List<EpochError>? records;
  AccuracyChartKind? kind;
  bool? corrected;
  Size? size;
  Color? foreground;
  Color? gridColor;
  Color? background;
  List<Color>? colors;
  double? textScale;
  String? fontFamily;
  Rect? plotRect;
  double? minimum;
  double? maximum;
}

class _AccuracyChartPainter extends CustomPainter {
  const _AccuracyChartPainter({
    required this.cache,
    required this.records,
    required this.kind,
    required this.corrected,
    required this.selected,
    required this.colors,
    required this.foreground,
    required this.gridColor,
    required this.background,
    required this.unit,
    required this.textScale,
    required this.fontFamily,
  });

  final List<EpochError> records;
  final _ChartCache cache;
  final AccuracyChartKind kind;
  final bool corrected;
  final EpochError? selected;
  final List<Color> colors;
  final Color foreground;
  final Color gridColor;
  final Color background;
  final String unit;
  final double textScale;
  final String? fontFamily;

  @override
  void paint(Canvas canvas, Size size) {
    if (records.isEmpty) return;
    if (cache.picture == null ||
        !identical(cache.records, records) ||
        cache.kind != kind ||
        cache.corrected != corrected ||
        cache.size != size ||
        cache.foreground != foreground ||
        cache.gridColor != gridColor ||
        cache.background != background ||
        !listEquals(cache.colors, colors) ||
        cache.textScale != textScale ||
        cache.fontFamily != fontFamily) {
      final recorder = ui.PictureRecorder();
      _paintSeries(Canvas(recorder), size);
      cache.picture?.dispose();
      cache.picture = recorder.endRecording();
      cache.records = records;
      cache.kind = kind;
      cache.corrected = corrected;
      cache.size = size;
      cache.foreground = foreground;
      cache.gridColor = gridColor;
      cache.background = background;
      cache.colors = List.unmodifiable(colors);
      cache.textScale = textScale;
      cache.fontFamily = fontFamily;
    }
    canvas.drawPicture(cache.picture!);
    if (selected != null) {
      final first = records.first.utcTime.microsecondsSinceEpoch;
      final last = records.last.utcTime.microsecondsSinceEpoch;
      final rect = cache.plotRect!;
      final px =
          rect.left +
          (selected!.utcTime.microsecondsSinceEpoch - first) /
              math.max(1, last - first) *
              rect.width;
      canvas.save();
      canvas.clipRect(rect.inflate(4));
      canvas.drawLine(
        Offset(px, rect.top),
        Offset(px, rect.bottom),
        Paint()
          ..color = foreground.withValues(alpha: .5)
          ..strokeWidth = 1,
      );
      if (cache.minimum != null && cache.maximum != null) {
        final vector = accuracyVector(selected!, kind, corrected);
        for (
          var axis = 0;
          axis < (kind == AccuracyChartKind.position ? 4 : 3);
          axis++
        ) {
          final value = _component(vector, axis);
          if (value == null || !value.isFinite) continue;
          final py =
              rect.bottom -
              (value - cache.minimum!) /
                  (cache.maximum! - cache.minimum!) *
                  rect.height;
          canvas.drawCircle(Offset(px, py), 4, Paint()..color = background);
          canvas.drawCircle(Offset(px, py), 2.5, Paint()..color = colors[axis]);
        }
      }
      canvas.restore();
    }
  }

  void _paintSeries(Canvas canvas, Size size) {
    if (records.isEmpty) return;
    final first = records.first.utcTime.microsecondsSinceEpoch;
    final last = records.last.utcTime.microsecondsSinceEpoch;
    final span = math.max(1, last - first);
    final axes = kind == AccuracyChartKind.position ? 4 : 3;
    var minimum = 0.0;
    var maximum = 0.0;
    var hasValue = false;
    for (final record in records) {
      final vector = accuracyVector(record, kind, corrected);
      for (var axis = 0; axis < axes; axis++) {
        final value = _component(vector, axis);
        if (value == null || !value.isFinite) continue;
        hasValue = true;
        minimum = math.min(minimum, value);
        maximum = math.max(maximum, value);
      }
    }
    if (!hasValue) {
      cache.minimum = cache.maximum = null;
      cache.plotRect = Rect.fromLTWH(0, 0, size.width, size.height);
      final message = _label('无可评定数据')..layout(maxWidth: size.width);
      message.paint(canvas, Offset(0, (size.height - message.height) / 2));
      return;
    }
    final padding = math.max(.001, (maximum - minimum) * .08);
    minimum -= padding;
    maximum += padding;
    cache.minimum = minimum;
    cache.maximum = maximum;
    final magnitude = math.max(minimum.abs(), maximum.abs());
    final scientific = magnitude < .01 || magnitude >= 10000;
    final decimals =
        (-math.log((maximum - minimum) / 4) / math.ln10).ceil().clamp(0, 6) + 1;
    String yLabel(double value) {
      if (value.abs() < (maximum - minimum) * 1e-10) return '0';
      return scientific
          ? value.toStringAsExponential(1).replaceFirst('e+', 'e')
          : value.toStringAsFixed(decimals);
    }

    final labelHeight = (_label('0.00')..layout()).height;
    var yLabelWidth = 0.0;
    for (var tick = 0; tick <= 4; tick++) {
      final label = _label(yLabel(minimum + (maximum - minimum) * tick / 4))
        ..layout();
      yLabelWidth = math.max(yLabelWidth, label.width);
    }
    final rect = Rect.fromLTRB(
      math.min(size.width * .48, yLabelWidth + 10),
      labelHeight + 12,
      math.max(size.width * .5, size.width - 8),
      math.max(labelHeight + 50, size.height - labelHeight - 16),
    );
    cache.plotRect = rect;
    double y(double value) =>
        rect.bottom - (value - minimum) / (maximum - minimum) * rect.height;
    double x(EpochError record) =>
        rect.left +
        (record.utcTime.microsecondsSinceEpoch - first) / span * rect.width;
    final grid = Paint()
      ..color = gridColor.withValues(alpha: .55)
      ..strokeWidth = .7;
    final yTicks = (rect.height / (labelHeight + 8)).floor().clamp(1, 4);
    for (var tick = 0; tick <= yTicks; tick++) {
      final value = minimum + (maximum - minimum) * tick / yTicks;
      final py = y(value);
      canvas.drawLine(Offset(rect.left, py), Offset(rect.right, py), grid);
      _text(
        canvas,
        yLabel(value),
        Offset(0, py - labelHeight / 2),
        maxWidth: rect.left - 6,
      );
    }
    canvas.drawLine(
      Offset(rect.left, y(0)),
      Offset(rect.right, y(0)),
      Paint()
        ..color = foreground.withValues(alpha: .22)
        ..strokeWidth = 1,
    );
    _text(canvas, unit, const Offset(0, 0));
    final duration = (last - first) / 1000000;
    String xLabel(double seconds) => duration < 1
        ? seconds.toStringAsPrecision(3)
        : seconds.toStringAsFixed(duration < 10 ? 1 : 0);
    var xWidth = 0.0;
    for (final seconds in [0.0, duration / 2, duration]) {
      xWidth = math.max(xWidth, (_label(xLabel(seconds))..layout()).width);
    }
    final ticks = rect.width >= xWidth * 3 + 16
        ? 3
        : rect.width >= xWidth * 2 + 8
        ? 2
        : 1;
    for (var tick = 0; tick < ticks; tick++) {
      final fraction = ticks == 1 ? .5 : tick / (ticks - 1);
      final label = _label(xLabel(duration * fraction))
        ..layout(maxWidth: rect.width);
      final px = ticks == 1
          ? rect.center.dx - label.width / 2
          : tick == 0
          ? rect.left
          : tick == ticks - 1
          ? rect.right - label.width
          : rect.center.dx - label.width / 2;
      label.paint(
        canvas,
        Offset(
          px.clamp(0, math.max(0, size.width - label.width)),
          rect.bottom + 8,
        ),
      );
    }
    canvas.save();
    canvas.clipRect(rect.inflate(1));
    for (var axis = 0; axis < axes; axis++) {
      final paint = Paint()
        ..color = colors[axis]
        ..strokeWidth = axis == 3 ? 1.25 : 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      int? bucket;
      double? bucketFirst, bucketLast, bucketMin, bucketMax;
      var connected = false;
      void flush() {
        if (bucket == null || bucketFirst == null) return;
        final px = rect.left + bucket;
        if (connected) {
          path.lineTo(px, y(bucketFirst));
        } else {
          path.moveTo(px, y(bucketFirst));
        }
        path.lineTo(px, y(bucketMin!));
        path.lineTo(px, y(bucketMax!));
        path.lineTo(px, y(bucketLast!));
        connected = true;
      }

      // Each screen column retains its first, last, minimum and maximum value.
      for (final record in records) {
        final value = _component(accuracyVector(record, kind, corrected), axis);
        if (value == null || !value.isFinite) {
          flush();
          bucket = null;
          bucketFirst = null;
          connected = false;
          continue;
        }
        final nextBucket = (x(record) - rect.left).floor();
        if (nextBucket != bucket) {
          flush();
          bucket = nextBucket;
          bucketFirst = bucketLast = bucketMin = bucketMax = value;
        } else {
          bucketLast = value;
          bucketMin = math.min(bucketMin!, value);
          bucketMax = math.max(bucketMax!, value);
        }
      }
      flush();
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  TextPainter _label(String text) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: foreground, fontSize: 12, fontFamily: fontFamily),
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(textScale),
    maxLines: 1,
    ellipsis: '…',
  );

  void _text(
    Canvas canvas,
    String text,
    Offset position, {
    double maxWidth = double.infinity,
  }) {
    final painter = _label(text)..layout(maxWidth: maxWidth);
    painter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant _AccuracyChartPainter oldDelegate) =>
      records != oldDelegate.records ||
      kind != oldDelegate.kind ||
      corrected != oldDelegate.corrected ||
      selected != oldDelegate.selected ||
      foreground != oldDelegate.foreground ||
      gridColor != oldDelegate.gridColor ||
      background != oldDelegate.background ||
      !listEquals(colors, oldDelegate.colors) ||
      textScale != oldDelegate.textScale ||
      fontFamily != oldDelegate.fontFamily;
}
