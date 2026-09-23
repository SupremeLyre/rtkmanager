import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'imu_data_parser.dart';
import 'imu_history.dart';
import 'app_ui.dart';

/// The same page consumes parsed serial frames or recorded phone frames.
class ImuVisualizationPage extends StatefulWidget {
  const ImuVisualizationPage({
    super.key,
    required this.dataStream,
    required this.sourceLabel,
    required this.emptyMessage,
    required this.onOpenDrawer,
    this.onOpenSource,
    this.active = true,
    this.sourceControl,
  });
  final Stream<ImuData> dataStream;
  final String sourceLabel;
  final String emptyMessage;
  final VoidCallback onOpenDrawer;
  final VoidCallback? onOpenSource;
  final bool active;
  final Widget? sourceControl;

  @override
  State<ImuVisualizationPage> createState() => _ImuVisualizationPageState();
}

class _ImuVisualizationPageState extends State<ImuVisualizationPage> {
  final _history = ImuHistory();
  final _clock = Stopwatch()..start();
  StreamSubscription<ImuData>? _subscription;
  Timer? _timer;
  bool _paused = false;
  int _seconds = 10;
  String? _error;
  Map<ImuVector, List<ImuPoint>> _points = {};
  Map<ImuVector, double> _rates = {};
  int _count = 0;
  int _end = 0;
  String _status = '等待数据';
  String _basis = '接收时间';

  @override
  void initState() {
    super.initState();
    _listen();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (widget.active && !_paused) _refresh(onlyIfChanged: true);
    });
  }

  void _listen() {
    _subscription = widget.dataStream.listen(
      (data) {
        _error = null;
        _history.add(
          data,
          arrivalUs: _clock.elapsedMicroseconds,
          now: DateTime.now(),
        );
      },
      onError: (Object error) {
        _error = '数据流异常：$error';
      },
    );
  }

  @override
  void didUpdateWidget(ImuVisualizationPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataStream != widget.dataStream) {
      unawaited(_subscription?.cancel());
      _history.clear();
      _error = null;
      _paused = false;
      _listen();
      _refresh();
    }
    if (widget.active && !oldWidget.active && !_paused) _refresh();
  }

  void _refresh({bool onlyIfChanged = false}) {
    final now = DateTime.now();
    final status =
        _error ??
        (_history.lastArrival == null
            ? '等待数据'
            : now.difference(_history.lastArrival!).inSeconds >= 2
            ? '数据已停止 · 保留最后画面'
            : '实时接收');
    if (onlyIfChanged && _count == _history.count && _status == status) return;
    setState(() {
      _points = {
        for (final kind in ImuVector.values)
          kind: _history.points(kind, _seconds),
      };
      _rates = {
        for (final kind in ImuVector.values) kind: _history.rate(kind, now),
      };
      _count = _history.count;
      _end = _history.latestTimeUs ?? 0;
      _basis = _history.timeBasis;
      _status = status;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppPageBar(title: 'IMU 数据可视化', onOpenDrawer: widget.onOpenDrawer),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 1050 &&
              MediaQuery.textScalerOf(context).scale(14) <= 21;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MobilePanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const MobileIconTile(Icons.show_chart, active: true),
                        Text(
                          widget.sourceLabel,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        MobileStatusChip(
                          _paused ? '显示已暂停' : _status,
                          icon: _paused
                              ? Icons.pause_circle_outline
                              : Icons.sensors,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (widget.sourceControl != null) ...[
                      widget.sourceControl!,
                      const SizedBox(height: 12),
                    ],
                    Text(
                      '$_basis · 最近 $_seconds 秒 · 已接收 $_count 帧',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          key: const ValueKey('imu-pause'),
                          onPressed: () {
                            setState(() => _paused = !_paused);
                            if (!_paused) _refresh();
                          },
                          icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                          label: Text(_paused ? '继续显示' : '暂停显示'),
                        ),
                        OutlinedButton.icon(
                          key: const ValueKey('imu-clear'),
                          onPressed: () {
                            _history.clear();
                            _refresh();
                          },
                          icon: const Icon(Icons.delete_sweep_outlined),
                          label: const Text('清除曲线'),
                        ),
                        for (final seconds in [5, 10, 30])
                          ChoiceChip(
                            label: Text('$seconds 秒'),
                            selected: _seconds == seconds,
                            onSelected: (_) {
                              setState(() => _seconds = seconds);
                              if (!_paused) _refresh();
                            },
                          ),
                        if (widget.onOpenSource != null)
                          TextButton.icon(
                            onPressed: widget.onOpenSource,
                            icon: const Icon(Icons.settings_input_component),
                            label: const Text('打开数据源'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '暂停与清除仅影响图表，采集和文件保存继续运行。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (_count == 0) ...[
                MobileEmptyState(
                  icon: Icons.monitor_heart_outlined,
                  title: '等待 IMU 数据',
                  message: widget.emptyMessage,
                ),
                const SizedBox(height: 12),
              ],
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final kind in ImuVector.values) ...[
                      if (kind != ImuVector.values.first)
                        const SizedBox(width: 12),
                      Expanded(child: _chart(kind)),
                    ],
                  ],
                )
              else
                for (final kind in ImuVector.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _chart(kind),
                  ),
            ],
          );
        },
      ),
    );
  }

  Widget _chart(ImuVector kind) => _VectorChart(
    kind: kind,
    points: _points[kind] ?? [],
    rate: _rates[kind] ?? 0,
    endUs: _end,
    seconds: _seconds,
  );
}

class _VectorChart extends StatelessWidget {
  const _VectorChart({
    required this.kind,
    required this.points,
    required this.rate,
    required this.endUs,
    required this.seconds,
  });
  final ImuVector kind;
  final List<ImuPoint> points;
  final double rate;
  final int endUs;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    final (title, unit, icon) = switch (kind) {
      ImuVector.acceleration => ('加速度', 'g', Icons.speed_outlined),
      ImuVector.gyroscope => ('角速度', '°/s', Icons.screen_rotation_outlined),
      ImuVector.magnetic => ('磁场', 'µT', Icons.explore_outlined),
    };
    final colors = Theme.of(context).brightness == Brightness.dark
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
    return MobilePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              Text(
                '$title · $unit',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              Text(
                '${rate.toStringAsFixed(1)} Hz',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                  '${['X', 'Y', 'Z'][axis]}  ${points.isEmpty ? '—' : points.last.values[axis].toStringAsFixed(3)}',
                  style: TextStyle(
                    color: colors[axis],
                    fontFamily: 'SourceCodePro',
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: RepaintBoundary(
              child: Semantics(
                label: '$title三轴曲线，单位$unit，最近$seconds秒',
                child: CustomPaint(
                  painter: _TracePainter(
                    points,
                    endUs,
                    seconds,
                    colors,
                    Theme.of(context).colorScheme,
                    MediaQuery.textScalerOf(context).scale(11).clamp(11, 16),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            points.isEmpty ? '未收到$title样本' : 'X 实线 · Y 长划线 · Z 点线  /  纵轴自动缩放',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _TracePainter extends CustomPainter {
  _TracePainter(
    this.points,
    this.endUs,
    this.seconds,
    this.colors,
    this.scheme,
    this.fontSize,
  );
  final List<ImuPoint> points;
  final int endUs;
  final int seconds;
  final List<Color> colors;
  final ColorScheme scheme;
  final double fontSize;

  String _label(double v) => v.abs() >= 10000
      ? v.toStringAsExponential(1)
      : v.toStringAsFixed(v.abs() >= 100 ? 0 : 2);
  void _text(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: fontSize,
          fontFamily: 'SourceCodePro',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(62, 10, size.width - 12, size.height - 28);
    if (rect.width <= 0) return;
    var low = double.infinity;
    var high = double.negativeInfinity;
    for (final p in points) {
      for (final v in p.values) {
        low = math.min(low, v);
        high = math.max(high, v);
      }
    }
    if (points.isEmpty) {
      low = -1;
      high = 1;
    }
    final pad = math.max((high - low) * .12, math.max(high.abs() * .01, .01));
    low -= pad;
    high += pad;
    final grid = Paint()
      ..color = scheme.outlineVariant
      ..strokeWidth = .6;
    for (var i = 0; i <= 4; i++) {
      final y = rect.top + rect.height * i / 4;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y), grid);
      _text(canvas, _label(high - (high - low) * i / 4), Offset(0, y - 7));
    }
    for (var i = 0; i <= 2; i++) {
      final x = rect.left + rect.width * i / 2;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
      _text(
        canvas,
        i == 2 ? '0 s' : '-${seconds * (2 - i) / 2} s',
        Offset(i == 2 ? x - 20 : x, rect.bottom + 8),
      );
    }
    canvas.save();
    canvas.clipRect(rect);
    for (var axis = 0; axis < 3; axis++) {
      final path = Path();
      int? previous;
      for (final p in points) {
        final x =
            rect.right - (endUs - p.timeUs) / (seconds * 1000000) * rect.width;
        final y =
            rect.bottom - (p.values[axis] - low) / (high - low) * rect.height;
        if (previous == null || p.timeUs - previous > 500000) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        previous = p.timeUs;
      }
      final pen = Paint()
        ..color = colors[axis]
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      if (axis == 0) {
        canvas.drawPath(path, pen);
      } else {
        final dash = axis == 1 ? 8.0 : 2.0;
        for (final metric in path.computeMetrics()) {
          for (double start = 0; start < metric.length; start += dash + 4) {
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
  bool shouldRepaint(_TracePainter oldDelegate) => true;
}
