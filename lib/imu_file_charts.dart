import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'imu_file_data.dart';

/// File charts retain the complete recording and share one inspection window.
class ImuFileCharts extends StatefulWidget {
  const ImuFileCharts({super.key, required this.dataset});

  final ImuFileDataset dataset;

  @override
  State<ImuFileCharts> createState() => _ImuFileChartsState();
}

class _ImuFileChartsState extends State<ImuFileCharts> {
  late RangeValues _range;
  late List<ImuFileVector> _available;

  RangeValues get _fullRange =>
      RangeValues(widget.dataset.start, widget.dataset.end);

  bool get _frameBased => widget.dataset.xAxisLabel.contains('帧');

  String _time(double value) => value.toStringAsFixed(_frameBased ? 0 : 3);

  @override
  void initState() {
    super.initState();
    _resetDataset();
  }

  @override
  void didUpdateWidget(covariant ImuFileCharts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.dataset, widget.dataset)) _resetDataset();
  }

  void _resetDataset() {
    _range = _fullRange;
    _available = [
      for (final kind in ImuFileVector.values)
        if ((widget.dataset.series[kind] ?? const <ImuFilePoint>[]).any(
          (point) => point.values.any((value) => value?.isFinite ?? false),
        ))
          kind,
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_available.isEmpty) {
      return const MobilePanel(child: Text('文件中没有可绘制的 IMU 数据'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MobilePanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '时间范围',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextButton.icon(
                    key: const ValueKey('imu-file-full-range'),
                    onPressed: _range == _fullRange
                        ? null
                        : () => setState(() => _range = _fullRange),
                    icon: const Icon(Icons.zoom_out_map, size: 18),
                    label: const Text('全部时段'),
                  ),
                ],
              ),
              Text(
                '显示范围：${_time(_range.start)} – ${_time(_range.end)} '
                '${_frameBased ? '帧' : 's'}',
              ),
              if (widget.dataset.end > widget.dataset.start)
                DrawerSwipeBlocker(
                  child: RangeSlider(
                    key: const ValueKey('imu-file-range'),
                    min: widget.dataset.start,
                    max: widget.dataset.end,
                    values: _range,
                    labels: RangeLabels(_time(_range.start), _time(_range.end)),
                    semanticFormatterCallback: (value) =>
                        '${_time(value)} ${_frameBased ? '帧' : '秒'}',
                    onChanged: (value) => setState(() => _range = value),
                  ),
                ),
              Text(
                widget.dataset.end > widget.dataset.start
                    ? '拖动两端可查看文件任意时段；缺失数据与时间跳变处断开显示。'
                    : '单个样本以圆点显示。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final minWidth = 360 * scale.clamp(1.0, 1.5);
            final columns = ((constraints.maxWidth + 12) / (minWidth + 12))
                .floor()
                .clamp(1, 3);
            final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final kind in _available)
                  SizedBox(
                    width: width,
                    child: _FileVectorChart(
                      kind: kind,
                      points: widget.dataset.series[kind]!,
                      range: _range,
                      xAxisLabel: widget.dataset.xAxisLabel,
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FileVectorChart extends StatelessWidget {
  const _FileVectorChart({
    required this.kind,
    required this.points,
    required this.range,
    required this.xAxisLabel,
  });

  final ImuFileVector kind;
  final List<ImuFilePoint> points;
  final RangeValues range;
  final String xAxisLabel;

  @override
  Widget build(BuildContext context) {
    final (title, unit, icon) = switch (kind) {
      ImuFileVector.acceleration => ('加速度', 'g', Icons.speed_outlined),
      ImuFileVector.gyroscope => ('角速度', '°/s', Icons.screen_rotation_outlined),
      ImuFileVector.magnetic => ('磁场', 'µT', Icons.explore_outlined),
      ImuFileVector.attitude => ('姿态时序', '°', Icons.threed_rotation),
      ImuFileVector.velocity => ('速度时序', 'm/s', Icons.moving_outlined),
    };
    final labels = switch (kind) {
      ImuFileVector.attitude => const ['Roll', 'Pitch', 'Yaw'],
      ImuFileVector.velocity => const ['E', 'N', 'U'],
      _ => const ['X', 'Y', 'Z'],
    };
    final theme = Theme.of(context);
    final colors = theme.brightness == Brightness.dark
        ? [
            Colors.lightBlue.shade200,
            Colors.orange.shade200,
            Colors.tealAccent.shade100,
          ]
        : [
            Colors.blue.shade800,
            Colors.deepOrange.shade800,
            Colors.teal.shade800,
          ];
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    return MobilePanel(
      key: ValueKey('imu-file-chart-${kind.name}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              Text(
                '$title · $unit',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              for (var axis = 0; axis < 3; axis++)
                Text(
                  '${labels[axis]} ${const ['实线', '长虚线', '点线'][axis]}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors[axis],
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 220 + math.max(0, scale - 1) * 50,
            child: RepaintBoundary(
              child: Semantics(
                label:
                    '$title，单位 $unit，横轴 $xAxisLabel，'
                    '${range.start} 至 ${range.end}',
                child: CustomPaint(
                  painter: _FileTracePainter(
                    points: points,
                    range: range,
                    kind: kind,
                    colors: colors,
                    scheme: theme.colorScheme,
                    textScale: scale,
                    fontFamily: theme.textTheme.bodySmall?.fontFamily,
                    frameBased: xAxisLabel.contains('帧'),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            xAxisLabel,
            textAlign: TextAlign.end,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Screen-column sampling preserves extrema without joining missing samples.
///
/// Coordinates remain in file time and value units. A one-point segment is
/// rendered as a dot. Even densely alternating valid/missing samples produce
/// at most four vertices per screen column.
class ImuFileTrace {
  ImuFileTrace._(this.segments);

  final List<List<Offset>> segments;

  factory ImuFileTrace.fromPoints({
    required List<ImuFilePoint> points,
    required int axis,
    required double start,
    required double end,
    required double pixelWidth,
    bool wrapDegrees = false,
  }) {
    final pixels = math.max(1, pixelWidth.ceil());
    final buckets = List<_TraceBucket?>.filled(pixels + 1, null);
    final span = end - start;
    ImuFilePoint? previous;
    double? previousValue;
    int? previousBucket;
    for (final point in points) {
      final value = axis < point.values.length ? point.values[axis] : null;
      if (!point.time.isFinite ||
          point.time < start ||
          point.time > end ||
          value == null ||
          !value.isFinite) {
        previous = null;
        previousValue = null;
        previousBucket = null;
        continue;
      }
      final connected =
          previous != null &&
          !point.breakBefore &&
          !(axis < point.axisBreaks.length && point.axisBreaks[axis]) &&
          point.time > previous.time &&
          (!wrapDegrees || (value - previousValue!).abs() <= 180);
      final bucketIndex = span > 0
          ? ((point.time - start) / span * pixels).floor().clamp(0, pixels)
          : pixels ~/ 2;
      final sample = Offset(point.time, value);
      final bucket = buckets[bucketIndex];
      if (bucket == null) {
        buckets[bucketIndex] = _TraceBucket(sample, connected);
      } else {
        // A clock reset can revisit a screen column from a different run.
        // Collapse such a column to separate dots, never a cross-run line.
        bucket.add(sample, connected && previousBucket == bucketIndex);
      }
      previous = point;
      previousValue = value;
      previousBucket = bucketIndex;
    }
    final segments = <List<Offset>>[];
    var active = <Offset>[];
    void flush() {
      if (active.isNotEmpty) segments.add(active);
      active = <Offset>[];
    }

    for (final bucket in buckets) {
      if (bucket == null) continue;
      final samples = bucket.samples;
      if (bucket.discontinuous) {
        flush();
        for (final sample in samples) {
          segments.add([sample]);
        }
      } else {
        if (!bucket.connectedFromPrevious) flush();
        active.addAll(samples);
      }
    }
    flush();
    return ImuFileTrace._(segments);
  }
}

class _TraceBucket {
  _TraceBucket(Offset sample, this.connectedFromPrevious)
    : first = sample,
      last = sample,
      minimum = sample,
      maximum = sample;

  final Offset first;
  final bool connectedFromPrevious;
  Offset last;
  Offset minimum;
  Offset maximum;
  bool discontinuous = false;

  void add(Offset sample, bool connected) {
    if (!connected) discontinuous = true;
    last = sample;
    if (sample.dy < minimum.dy) minimum = sample;
    if (sample.dy > maximum.dy) maximum = sample;
  }

  List<Offset> get samples =>
      {first, minimum, maximum, last}.toList()
        ..sort((left, right) => left.dx.compareTo(right.dx));
}

class _FileTracePainter extends CustomPainter {
  const _FileTracePainter({
    required this.points,
    required this.range,
    required this.kind,
    required this.colors,
    required this.scheme,
    required this.textScale,
    required this.fontFamily,
    required this.frameBased,
  });

  final List<ImuFilePoint> points;
  final RangeValues range;
  final ImuFileVector kind;
  final List<Color> colors;
  final ColorScheme scheme;
  final double textScale;
  final String? fontFamily;
  final bool frameBased;

  TextPainter _label(String text) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: 11,
        fontFamily: fontFamily,
      ),
    ),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.linear(textScale),
    maxLines: 1,
    ellipsis: '…',
  );

  @override
  void paint(Canvas canvas, Size size) {
    final traces = [
      for (var axis = 0; axis < 3; axis++)
        ImuFileTrace.fromPoints(
          points: points,
          axis: axis,
          start: range.start,
          end: range.end,
          pixelWidth: size.width,
          wrapDegrees: kind == ImuFileVector.attitude && axis == 2,
        ),
    ];
    var minimum = 0.0;
    var maximum = 0.0;
    var hasValues = false;
    for (final trace in traces) {
      for (final segment in trace.segments) {
        for (final sample in segment) {
          hasValues = true;
          minimum = math.min(minimum, sample.dy);
          maximum = math.max(maximum, sample.dy);
        }
      }
    }
    if (!hasValues) {
      final message = _label('该范围无有效数据')..layout(maxWidth: size.width);
      message.paint(canvas, Offset(0, (size.height - message.height) / 2));
      return;
    }
    final padding = math.max(.01, (maximum - minimum) * .08);
    minimum -= padding;
    maximum += padding;
    final decimals =
        (-math.log((maximum - minimum) / 4) / math.ln10).ceil().clamp(0, 5) + 1;
    String yLabel(double value) {
      if (value.abs() < (maximum - minimum) * 1e-10) return '0';
      return value.abs() >= 10000
          ? value.toStringAsExponential(1)
          : value.toStringAsFixed(decimals);
    }

    var labelWidth = 0.0;
    final labelHeight = (_label('0')..layout()).height;
    for (var tick = 0; tick <= 4; tick++) {
      final label = _label(yLabel(minimum + (maximum - minimum) * tick / 4))
        ..layout();
      labelWidth = math.max(labelWidth, label.width);
    }
    final plot = Rect.fromLTRB(
      math.min(size.width * .45, labelWidth + 8),
      labelHeight / 2 + 4,
      size.width - 4,
      size.height - labelHeight - 14,
    );
    if (plot.width <= 1 || plot.height <= 1) return;
    double x(double time) => range.end == range.start
        ? plot.center.dx
        : plot.left +
              (time - range.start) / (range.end - range.start) * plot.width;
    double y(double value) =>
        plot.bottom - (value - minimum) / (maximum - minimum) * plot.height;
    final grid = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: .7)
      ..strokeWidth = .7;
    final yTicks = (plot.height / (labelHeight + 10)).floor().clamp(1, 4);
    for (var tick = 0; tick <= yTicks; tick++) {
      final value = minimum + (maximum - minimum) * tick / yTicks;
      final py = y(value);
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), grid);
      final label = _label(yLabel(value))..layout(maxWidth: plot.left - 6);
      label.paint(canvas, Offset(0, py - label.height / 2));
    }
    canvas.drawLine(
      Offset(plot.left, y(0)),
      Offset(plot.right, y(0)),
      Paint()
        ..color = scheme.onSurfaceVariant.withValues(alpha: .35)
        ..strokeWidth = 1,
    );
    String xLabel(double value) => frameBased
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(range.end - range.start < 10 ? 2 : 1);
    final endpoints = [xLabel(range.start), xLabel(range.end)];
    final widths = [
      for (final text in endpoints) (_label(text)..layout()).width,
    ];
    final tickCount = plot.width >= widths.reduce(math.max) * 3 + 16 ? 3 : 2;
    for (var tick = 0; tick < tickCount; tick++) {
      final fraction = tick / (tickCount - 1);
      final label = _label(
        xLabel(range.start + (range.end - range.start) * fraction),
      )..layout(maxWidth: plot.width / tickCount);
      final px = plot.left + plot.width * fraction;
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom), grid);
      label.paint(
        canvas,
        Offset(
          (px - label.width * fraction).clamp(0, size.width - label.width),
          plot.bottom + 8,
        ),
      );
    }
    canvas.save();
    canvas.clipRect(plot.inflate(3));
    for (var axis = 0; axis < traces.length; axis++) {
      final pen = Paint()
        ..color = colors[axis]
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (final segment in traces[axis].segments) {
        if (segment.length == 1) {
          canvas.drawCircle(
            Offset(x(segment.single.dx), y(segment.single.dy)),
            2.4,
            Paint()..color = colors[axis],
          );
          continue;
        }
        path.moveTo(x(segment.first.dx), y(segment.first.dy));
        for (final sample in segment.skip(1)) {
          path.lineTo(x(sample.dx), y(sample.dy));
        }
      }
      if (axis == 0) {
        canvas.drawPath(path, pen);
      } else {
        final dash = axis == 1 ? 8.0 : 2.0;
        for (final metric in path.computeMetrics()) {
          for (var start = 0.0; start < metric.length; start += dash + 4) {
            canvas.drawPath(
              metric.extractPath(start, math.min(start + dash, metric.length)),
              pen,
            );
          }
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FileTracePainter oldDelegate) =>
      !identical(points, oldDelegate.points) ||
      range != oldDelegate.range ||
      kind != oldDelegate.kind ||
      !listEquals(colors, oldDelegate.colors) ||
      scheme != oldDelegate.scheme ||
      textScale != oldDelegate.textScale ||
      fontFamily != oldDelegate.fontFamily ||
      frameBased != oldDelegate.frameBased;
}
