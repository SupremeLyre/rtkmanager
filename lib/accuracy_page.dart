import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'accuracy_chart.dart';
import 'accuracy_controller.dart';
import 'accuracy_evaluation.dart';
import 'app_ui.dart';
import 'truth_data.dart';

class AccuracyPage extends StatefulWidget {
  const AccuracyPage({
    super.key,
    required this.controller,
    this.onOpenDrawer,
    this.onShowPositioning,
    this.mobileLayout = false,
  });

  final AccuracyController controller;
  final VoidCallback? onOpenDrawer;
  final VoidCallback? onShowPositioning;
  final bool mobileLayout;

  @override
  State<AccuracyPage> createState() => _AccuracyPageState();
}

class _AccuracyPageState extends State<AccuracyPage> {
  final _gap = TextEditingController(text: '2');
  final _offset = TextEditingController(text: '0');
  final _ggaDate = TextEditingController();
  final _calibrationStart = TextEditingController();
  final _calibrationEnd = TextEditingController();
  final _stableRtkDuration = TextEditingController(text: '10');
  final _stableRtkGap = TextEditingController(text: '2');
  final _stationarySpeed = TextEditingController(text: '0.1');
  final _stablePosition = TextEditingController(text: '0.2');
  bool _calibrate = true;
  bool _corrected = true;
  AccuracyChartKind _kind = AccuracyChartKind.position;
  bool get _displayCorrected =>
      _corrected &&
      widget.controller.options.calibrate &&
      _currentLayer?.calibration.applied == true;
  bool _previewBusy = false;
  String? _layerId;
  AccuracyEvaluation? _lastEvaluation;
  final Map<String, List<EpochError>> _sortedRecords = {};

  LayerAccuracyEvaluation? get _currentLayer {
    final layers =
        widget.controller.evaluation?.layers ?? <LayerAccuracyEvaluation>[];
    final selectedId = widget.controller.selectedPoint?.layerId;
    return layers.where((item) => item.layerId == selectedId).firstOrNull ??
        layers.where((item) => item.layerId == _layerId).firstOrNull ??
        layers.firstOrNull;
  }

  @override
  void dispose() {
    for (final controller in [
      _gap,
      _offset,
      _ggaDate,
      _calibrationStart,
      _calibrationEnd,
      _stableRtkDuration,
      _stableRtkGap,
      _stationarySpeed,
      _stablePosition,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _importTruth() async {
    try {
      final picked = await FilePicker.platform.pickFiles(dialogTitle: '导入真值文件');
      final path = picked?.files.firstOrNull?.path;
      if (path == null || !mounted) return;
      setState(() => _previewBusy = true);
      final preview = await previewTruthFile(path);
      if (!mounted) return;
      setState(() => _previewBusy = false);
      final configuration = await showDialog<_TruthImportConfiguration>(
        context: context,
        builder: (_) => _TruthMappingDialog(path: path, preview: preview),
      );
      if (!mounted || configuration == null) return;
      await widget.controller.importTruth(
        path,
        mapping: configuration.mapping,
        gpsUtcOffsetSeconds: configuration.gpsOffset,
      );
    } catch (error) {
      if (mounted) widget.controller.reportError('真值预览失败：$error');
    } finally {
      if (mounted && _previewBusy) setState(() => _previewBusy = false);
    }
  }

  void _evaluate() {
    try {
      final gap = double.tryParse(_gap.text.trim());
      final offset = double.tryParse(_offset.text.trim());
      final stableDuration = double.tryParse(_stableRtkDuration.text.trim());
      final stableGap = double.tryParse(_stableRtkGap.text.trim());
      final stationarySpeed = double.tryParse(_stationarySpeed.text.trim());
      final stablePosition = double.tryParse(_stablePosition.text.trim());
      if (gap == null ||
          !gap.isFinite ||
          gap <= 0 ||
          offset == null ||
          !offset.isFinite) {
        throw const FormatException('插值最大间隔须为正数，时间偏移须为有限数值。');
      }
      if (stableDuration == null ||
          !stableDuration.isFinite ||
          stableDuration < 0 ||
          stableGap == null ||
          !stableGap.isFinite ||
          stableGap <= 0) {
        throw const FormatException('连续静止最短时长须为非负数，静态解最大间隔须为正数。');
      }
      if (stationarySpeed == null ||
          !stationarySpeed.isFinite ||
          stationarySpeed < 0 ||
          stablePosition == null ||
          !stablePosition.isFinite ||
          stablePosition <= 0) {
        throw const FormatException('静止速度阈值须为非负数，静态位置漂移阈值须为正数。');
      }
      DateTime? date(String value, String label) {
        if (value.trim().isEmpty) return null;
        final normalized = value.trim();
        final match = RegExp(
          r'^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?)?(Z|[+-]\d{2}:\d{2})?$',
        ).firstMatch(normalized);
        if (match == null) throw FormatException('$label 格式无效。');
        final values = [
          for (var i = 1; i <= 6; i++) int.parse(match[i] ?? '0'),
        ];
        final calendar = DateTime.utc(
          values[0],
          values[1],
          values[2],
          values[3],
          values[4],
          values[5],
        );
        if (calendar.year != values[0] ||
            calendar.month != values[1] ||
            calendar.day != values[2] ||
            calendar.hour != values[3] ||
            calendar.minute != values[4] ||
            calendar.second != values[5]) {
          throw FormatException('$label 日期或时间无效。');
        }
        if (match[4] == null) return calendar;
        final parsed = DateTime.tryParse(
          match[8] != null ? normalized : '${normalized}Z',
        );
        if (parsed == null) {
          throw FormatException('$label 格式无效，请使用 YYYY-MM-DD 或 UTC ISO 时间。');
        }
        return parsed.toUtc();
      }

      final start = date(_calibrationStart.text, '标定起始时间');
      final end = date(_calibrationEnd.text, '标定结束时间');
      if (start != null && end != null && start.isAfter(end)) {
        throw const FormatException('标定起始时间应早于结束时间。');
      }
      widget.controller.evaluate(
        options: EvaluationOptions(
          calibrate: _calibrate,
          maxInterpolationGapSeconds: gap,
          timeOffsetSeconds: offset,
          ggaDate: date(_ggaDate.text, 'GGA 日期'),
          calibrationStart: start,
          calibrationEnd: end,
          stableRtkMinDurationSeconds: stableDuration,
          stableRtkMaxGapSeconds: stableGap,
          stationarySpeedThresholdMps: stationarySpeed,
          stablePositionThresholdMeters: stablePosition,
        ),
      );
    } catch (error) {
      widget.controller.reportError(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final evaluation = controller.evaluation;
      if (!identical(evaluation, _lastEvaluation)) {
        _lastEvaluation = evaluation;
        _sortedRecords.clear();
        for (final layer in evaluation?.layers ?? <LayerAccuracyEvaluation>[]) {
          _sortedRecords[layer.layerId] = List.of(layer.records)
            ..sort((a, b) => a.utcTime.compareTo(b.utcTime));
        }
      }
      final layers = evaluation?.layers ?? <LayerAccuracyEvaluation>[];
      final layer = _currentLayer;
      final busy = controller.busy || _previewBusy;
      return Scaffold(
        appBar: AppPageBar(
          title: '精度评定',
          onOpenDrawer: widget.onOpenDrawer,
          actions: [
            IconButton(
              key: const ValueKey('accuracy-settings'),
              tooltip: '评定设置',
              onPressed: busy ? null : _showSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
            IconButton(
              tooltip: '评定说明',
              onPressed: _showHelp,
              icon: const Icon(Icons.help_outline_rounded),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(widget.mobileLayout ? 12 : 20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _dataToolbar(context, busy),
                    if (busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: LinearProgressIndicator(),
                      ),
                    if (controller.error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          controller.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    if (layer != null) ...[
                      const SizedBox(height: 16),
                      _layerToolbar(context, layers, layer),
                      const SizedBox(height: 12),
                      _summaries(context, layer),
                      const SizedBox(height: 16),
                      _chartPanel(context, layer),
                      const SizedBox(height: 12),
                      _statistics(context, layer),
                      const SizedBox(height: 8),
                      _calibration(context, layer),
                      const SizedBox(height: 8),
                    ] else if (!busy)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(
                          children: [
                            Icon(
                              Icons.query_stats_rounded,
                              size: 48,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '对齐真值，查看误差',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            const Text('导入轨迹与真值后开始评定'),
                          ],
                        ),
                      ),
                    _dataDetails(context, evaluation),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _surface(BuildContext context, Widget child, {EdgeInsets? padding}) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .65)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  Widget _dataToolbar(BuildContext context, bool busy) {
    final controller = widget.controller;
    final truth = controller.truth;
    final counts = Text(
      '定位 ${controller.points.length} 点 · ${truth == null ? '尚未导入真值' : '真值 ${truth.samples.length} 点'}',
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: busy ? null : _importTruth,
          icon: const Icon(Icons.upload_file_outlined, size: 18),
          label: Text(truth == null ? '导入真值' : '更换真值'),
        ),
        FilledButton.icon(
          key: const ValueKey('accuracy-evaluate'),
          onPressed: busy || truth == null || controller.points.isEmpty
              ? null
              : _evaluate,
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          label: const Text('开始评定'),
        ),
      ],
    );
    return _surface(
      context,
      LayoutBuilder(
        builder: (context, constraints) {
          final scaled = MediaQuery.textScalerOf(context).scale(1);
          if (constraints.maxWidth < 600 * scaled) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [counts, const SizedBox(height: 12), actions],
            );
          }
          return Row(
            children: [
              Expanded(child: counts),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _layerToolbar(
    BuildContext context,
    List<LayerAccuracyEvaluation> layers,
    LayerAccuracyEvaluation layer,
  ) {
    final dropdown = DropdownButtonFormField<String>(
      key: ValueKey('accuracy-layer-${layer.layerId}'),
      initialValue: layer.layerId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '评定图层',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      selectedItemBuilder: (context) => [
        for (final item in layers)
          Tooltip(
            message: item.sourcePath ?? '实时轨迹',
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      items: [
        for (final item in layers)
          DropdownMenuItem(
            value: item.layerId,
            child: Text(
              '${item.label} · ${item.sourcePath ?? '实时轨迹'}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (id) {
        setState(() => _layerId = id);
        final records = _sortedRecords[id];
        if (records != null && records.isNotEmpty) {
          widget.controller.selectPoint(records.first.point);
        }
      },
    );
    final calibration = layer.calibration;
    final metricCalibrated = switch (_kind) {
      AccuracyChartKind.position => calibration.positionCount > 0,
      AccuracyChartKind.velocity => calibration.velocityCount > 0,
      AccuracyChartKind.attitude =>
        calibration.attitudeCount > 0 || calibration.tiltCount > 0,
    };
    final modeLabel = !_displayCorrected
        ? '原始误差'
        : !metricCalibrated
        ? '本项未标定'
        : _kind == AccuracyChartKind.attitude && calibration.attitudeCount == 0
        ? '水平已修正'
        : '已修正';
    final mode = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(modeLabel, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(width: 6),
        Tooltip(
          message: '显示扣除固定系统差后的误差；未标定分量保留原始值',
          child: DrawerSwipeBlocker(
            child: Switch.adaptive(
              key: const ValueKey('accuracy-corrected-toggle'),
              value: _displayCorrected,
              onChanged:
                  !widget.controller.options.calibrate ||
                      !layer.calibration.applied
                  ? null
                  : (value) => setState(() => _corrected = value),
            ),
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <
            550 * MediaQuery.textScalerOf(context).scale(1)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              dropdown,
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      '匹配 ${layer.records.length} 点',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  mode,
                ],
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: dropdown),
            const SizedBox(width: 16),
            mode,
          ],
        );
      },
    );
  }

  Widget _summaries(BuildContext context, LayerAccuracyEvaluation layer) {
    final statistics = _displayCorrected
        ? layer.statistics
        : layer.rawStatistics;
    final velocity = statistics['velocity'];
    final items = [
      (
        AccuracyChartKind.position,
        '水平位置',
        statistics['position']?.horizontalRmse,
        'm',
      ),
      (
        AccuracyChartKind.velocity,
        velocity?.threeDimensionalRmse != null ? '三维速度' : '水平速度',
        velocity?.threeDimensionalRmse ?? velocity?.horizontalRmse,
        'm/s',
      ),
      (AccuracyChartKind.attitude, '航向', statistics['attitude']?.z.rmse, '°'),
    ];
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final columns = constraints.maxWidth >= 300 * scale ? 3 : 1;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final (kind, title, value, unit) in items)
              SizedBox(
                width: width,
                child: Material(
                  color: _kind == kind
                      ? colors.primaryContainer.withValues(alpha: .35)
                      : colors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(
                      color: _kind == kind
                          ? colors.primary.withValues(alpha: .45)
                          : colors.outlineVariant,
                    ),
                  ),
                  child: InkWell(
                    key: ValueKey('accuracy-summary-${kind.name}'),
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => setState(() => _kind = kind),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            value?.toStringAsFixed(3) ?? '—',
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: colors.onSurface,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'RMSE · $unit',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _chartPanel(BuildContext context, LayerAccuracyEvaluation layer) {
    final records = _sortedRecords[layer.layerId]!;
    return _surface(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) =>
                SegmentedButton<AccuracyChartKind>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.standard,
                  ),
                  segments: [
                    for (final kind in AccuracyChartKind.values)
                      ButtonSegment(
                        value: kind,
                        label: Text(switch (kind) {
                          AccuracyChartKind.position => '位置',
                          AccuracyChartKind.velocity => '速度',
                          AccuracyChartKind.attitude => '姿态',
                        }, key: ValueKey('accuracy-kind-${kind.name}')),
                      ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (values) =>
                      setState(() => _kind = values.first),
                ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) => AccuracyTimeChart(
              records: records,
              kind: _kind,
              corrected: _displayCorrected,
              height: constraints.maxWidth >= 700 ? 260 : 220,
              selectedPoint: widget.controller.selectedPoint,
              onSelected: (record) =>
                  widget.controller.selectPoint(record.point),
            ),
          ),
          const Divider(height: 24),
          _selection(context, records),
        ],
      ),
    );
  }

  Widget _selection(BuildContext context, List<EpochError> records) {
    if (records.isEmpty) return const Text('无匹配历元');
    final controller = widget.controller;
    final index = records.indexWhere(
      (record) => identical(record.point, controller.selectedPoint),
    );
    if (index < 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('当前定位点未匹配真值'),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => controller.selectPoint(records.first.point),
            child: const Text('选择首个匹配历元'),
          ),
        ],
      );
    }
    final selected = records[index];
    final vector = accuracyVector(selected, _kind, _displayCorrected);
    final attitude = _kind == AccuracyChartKind.attitude;
    final imu = selected.point.imuData;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            Text(
              accuracyUtcLabel(selected.utcTime),
              key: const ValueKey('accuracy-selected-time'),
              style: Theme.of(context).textTheme.labelMedium,
            ),
            if (attitude && imu != null && !imu.headingReady)
              Text(
                imu.horizontalAttitudeReady ? '航向对准中' : '姿态未就绪',
                key: const ValueKey('accuracy-attitude-readiness'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final cellWidth = (constraints.maxWidth - 16) / 3;
            final stack =
                cellWidth < 95 * MediaQuery.textScalerOf(context).scale(1);
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (axis, name, value) in [
                  ('x', attitude ? 'Roll' : 'E', vector.x),
                  ('y', attitude ? 'Pitch' : 'N', vector.y),
                  ('z', attitude ? 'Heading' : 'U', vector.z),
                ])
                  SizedBox(
                    width: stack ? constraints.maxWidth : cellWidth,
                    child: Row(
                      children: [
                        Text(
                          name,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _number(value),
                            key: ValueKey('accuracy-selected-error-$axis'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        DrawerSwipeBlocker(
          child: Slider(
            key: const ValueKey('accuracy-epoch-slider'),
            value: index.toDouble(),
            min: 0,
            max: records.length > 1 ? (records.length - 1).toDouble() : 1,
            label: accuracyUtcLabel(selected.utcTime),
            onChanged: records.length < 2
                ? null
                : (value) =>
                      controller.selectPoint(records[value.round()].point),
          ),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '上一误差历元',
                  onPressed: index > 0
                      ? () => controller.selectPoint(records[index - 1].point)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${index + 1} / ${records.length}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                IconButton(
                  tooltip: '下一误差历元',
                  onPressed: index < records.length - 1
                      ? () => controller.selectPoint(records[index + 1].point)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            TextButton.icon(
              key: const ValueKey('accuracy-show-map'),
              onPressed: widget.onShowPositioning == null
                  ? null
                  : () {
                      controller.locateSelectedPoint();
                      widget.onShowPositioning!();
                    },
              icon: const Icon(Icons.map_outlined, size: 18),
              label: const Text('查看地图'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _details(
    BuildContext context, {
    required String id,
    required String title,
    required List<Widget> children,
  }) => _surface(
    context,
    Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: ValueKey(id),
        title: Text(title, style: Theme.of(context).textTheme.titleSmall),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
    padding: EdgeInsets.zero,
  );

  Widget _dataDetails(BuildContext context, AccuracyEvaluation? evaluation) {
    final truth = widget.controller.truth;
    final layer = _currentLayer;
    return _details(
      context,
      id: 'accuracy-data-details',
      title: '数据详情',
      children: [
        if (layer != null) ...[
          const Text('定位文件'),
          SelectableText(layer.sourcePath ?? '实时轨迹'),
          const SizedBox(height: 12),
        ],
        if (truth != null) ...[
          const Text('真值文件'),
          SelectableText(truth.sourcePath),
          if (truth.samples.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(accuracyUtcLabel(truth.samples.first.utcTime)),
            Text('至 ${accuracyUtcLabel(truth.samples.last.utcTime)}'),
          ],
          if (truth.skippedRows > 0) Text('跳过 ${truth.skippedRows} 行无效数据'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.controller.busy
                  ? null
                  : widget.controller.clearTruth,
              icon: const Icon(Icons.close_rounded, size: 18),
              label: const Text('移除真值'),
            ),
          ),
        ],
        if (evaluation != null) ...[
          Text(
            '匹配 ${evaluation.records.length} / ${widget.controller.points.length} 点 · 未匹配 ${evaluation.unmatchedCount} 点',
          ),
          for (final entry in evaluation.unmatchedReasons.entries)
            Text('${entry.key}：${entry.value}'),
        ],
        if (truth == null && layer == null) const Text('尚未导入数据'),
      ],
    );
  }

  Widget _statistics(BuildContext context, LayerAccuracyEvaluation layer) {
    final statistics = _displayCorrected
        ? layer.statistics
        : layer.rawStatistics;
    final stats = statistics[_kind.name];
    final attitude = _kind == AccuracyChartKind.attitude;
    return _details(
      context,
      id: 'accuracy-statistics-details',
      title: '详细统计',
      children: [
        if (stats != null) ...[
          if (attitude)
            Text(
              '航向有效 ${stats.z.count} / ${layer.records.length} 点',
              key: const ValueKey('accuracy-heading-valid-count'),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 20,
              columns: [
                for (final name in ['分量', '点数', '均值', 'RMSE', '标准差'])
                  DataColumn(label: Text(name)),
              ],
              rows: [
                for (final (axis, label) in [
                  (stats.x, attitude ? 'Roll' : 'E'),
                  (stats.y, attitude ? 'Pitch' : 'N'),
                  (stats.z, attitude ? 'Heading' : 'U'),
                ])
                  DataRow(
                    cells: [
                      DataCell(Text(label)),
                      DataCell(Text('${axis.count}')),
                      DataCell(Text(_number(axis.bias))),
                      DataCell(Text(_number(axis.rmse))),
                      DataCell(Text(_number(axis.std))),
                    ],
                  ),
              ],
            ),
          ),
          if (!attitude)
            Text(
              '水平 RMSE ${_number(stats.horizontalRmse)} · 三维 RMSE ${_number(stats.threeDimensionalRmse)}',
            ),
        ] else
          const Text('暂无有效分量'),
      ],
    );
  }

  Widget _calibration(BuildContext context, LayerAccuracyEvaluation layer) {
    final c = layer.calibration;
    return _details(
      context,
      id: 'accuracy-calibration-details',
      title: '标定详情',
      children: [
        if (!c.applied) const Text('未完成标定'),
        if (c.intervalStart != null && c.intervalEnd != null) ...[
          Text('连续静止段 · ${c.stableRtkCount} 点'),
          Text(
            accuracyUtcLabel(c.intervalStart!),
            key: const ValueKey('accuracy-calibration-start'),
          ),
          Text(
            '至 ${accuracyUtcLabel(c.intervalEnd!)}',
            key: const ValueKey('accuracy-calibration-end'),
          ),
          const SizedBox(height: 12),
        ],
        Text('位置 E / N / U · ${c.positionCount} 点'),
        Text('${_vector(c.positionOffset)} m'),
        const SizedBox(height: 8),
        Text('速度 E / N / U · ${c.velocityCount} 点'),
        Text('${_vector(c.velocityOffset)} m/s'),
        const SizedBox(height: 8),
        const Text('姿态 Roll / Pitch / Heading'),
        Text('${_vector(c.attitudeOffset)} °'),
        Text('水平姿态 ${c.tiltCount} 点 · 航向 ${c.headingCount} 点'),
        if (c.attitudeReferenceTime != null) ...[
          const SizedBox(height: 12),
          const Text('最后有效 FIX 参照'),
          Text(
            accuracyUtcLabel(c.attitudeReferenceTime!),
            key: const ValueKey('accuracy-attitude-reference-time'),
          ),
        ],
        if (c.headingBiasCount > 0 || c.headingCount > 0 || c.tiltCount > 0)
          Text(
            '航向差 ${_number(c.headingBias)} ° · ${c.headingBiasCount} 点',
            key: const ValueKey('accuracy-heading-bias'),
          ),
        if (c.tiltCount > 0 && c.attitudeCount == 0)
          const Text('仅修正 Roll / Pitch，缺少有效航向 FIX 参照。'),
        if (c.unavailableReason != null) ...[
          const SizedBox(height: 12),
          Text(c.unavailableReason!),
        ],
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String hint, {
    bool numeric = false,
  }) => TextField(
    controller: controller,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true, signed: true)
        : TextInputType.datetime,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      border: const OutlineInputBorder(),
    ),
  );

  Future<void> _showSettings() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 760),
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, updateSheet) {
        return Padding(
          key: const ValueKey('accuracy-settings-sheet'),
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .85,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('评定设置', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 20),
                  Text('时间对齐', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 12),
                  _settingsFields(context, [
                    _field(_gap, '插值最大间隔（秒）', '2', numeric: true),
                    _field(_offset, '定位时间偏移（秒）', '0', numeric: true),
                    _field(_ggaDate, 'GGA 首日 UTC 日期（可选）', '2026-10-29'),
                  ]),
                  const SizedBox(height: 20),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动修正系统差'),
                    value: _calibrate,
                    onChanged: (value) {
                      setState(() => _calibrate = value);
                      updateSheet(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  Text('静止段', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 12),
                  _settingsFields(context, [
                    _field(
                      _calibrationStart,
                      '静止标定起始 UTC（可选）',
                      '2026-10-29T01:00:00',
                    ),
                    _field(
                      _calibrationEnd,
                      '静止标定结束 UTC（可选）',
                      '2026-10-29T01:10:00',
                    ),
                    _field(
                      _stableRtkDuration,
                      '连续静止最短时长（秒）',
                      '10',
                      numeric: true,
                    ),
                    _field(_stableRtkGap, '静态解最大间隔（秒）', '2', numeric: true),
                    _field(
                      _stationarySpeed,
                      '静止速度阈值（m/s）',
                      '0.1',
                      numeric: true,
                    ),
                    _field(
                      _stablePosition,
                      '静态位置漂移阈值（m）',
                      '0.2',
                      numeric: true,
                    ),
                  ]),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const ValueKey('accuracy-settings-apply'),
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('应用设置'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _settingsFields(BuildContext context, List<Widget> fields) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final columns =
              constraints.maxWidth >=
                  600 * MediaQuery.textScalerOf(context).scale(1)
              ? 2
              : 1;
          final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
          return Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final field in fields) SizedBox(width: width, child: field),
            ],
          );
        },
      );

  void _showHelp() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('评定说明', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            const Text('时间对齐'),
            const Text('按 UTC 插值匹配真值，不外推。时间偏移加到定位时间上，超出插值间隔的点不参与评定。'),
            const SizedBox(height: 16),
            const Text('固定系统差'),
            const Text(
              '位置、速度使用首段连续稳定的静态 RTK / PPP 解估计一次偏差，所有历元共用。姿态使用最后一个有效 FIX 历元估计一次安装角差。',
            ),
            const SizedBox(height: 16),
            const Text('姿态有效性'),
            const Text(
              '水平对准后评定 Roll / Pitch，航向对准后才计入航向 RMSE。缺失项显示 —；已就绪的纯惯导历元仍参与评定。',
            ),
            const SizedBox(height: 16),
            const Text('修正后数值为扣除固定系统差后的残差。同一批数据标定的残差不能代替独立验证精度。'),
          ],
        ),
      ),
    ),
  );
}

String _number(double? value) => value?.toStringAsFixed(4) ?? '—';
String _vector(ErrorVector vector) =>
    '${_number(vector.x)} / ${_number(vector.y)} / ${_number(vector.z)}';

const _fieldLabels = {
  TruthField.gpsWeek: 'GPS 周',
  TruthField.gpsSeconds: 'GPS 周内秒',
  TruthField.utcTime: 'UTC 时间',
  TruthField.latitude: '纬度（必选）',
  TruthField.longitude: '经度（必选）',
  TruthField.height: '椭球高',
  TruthField.velocityEast: '东向速度 E',
  TruthField.velocityNorth: '北向速度 N',
  TruthField.velocityUp: '天向速度 U',
  TruthField.roll: '横滚 Roll',
  TruthField.pitch: '俯仰 Pitch',
  TruthField.heading: '航向 Heading',
};

class _TruthImportConfiguration {
  const _TruthImportConfiguration(this.mapping, this.gpsOffset);
  final TruthColumnMapping mapping;
  final int gpsOffset;
}

class _TruthMappingDialog extends StatefulWidget {
  const _TruthMappingDialog({required this.path, required this.preview});
  final String path;
  final TruthFilePreview preview;

  @override
  State<_TruthMappingDialog> createState() => _TruthMappingDialogState();
}

class _TruthMappingDialogState extends State<_TruthMappingDialog> {
  late final Map<TruthField, int> _columns = Map.of(
    widget.preview.mapping.columns,
  );
  final _gpsOffset = TextEditingController(text: '18');
  String? _error;

  @override
  void dispose() {
    _gpsOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final headers = widget.preview.headers;
    return AlertDialog(
      title: const Text('真值列映射'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(widget.path),
              const SizedBox(height: 8),
              const Text(
                '仅读取选定列。时间需指定 UTC，或同时指定 GPS 周及周内秒。未选择的速度和姿态分量保留为空。角度单位为度，速度为 m/s。',
              ),
              const SizedBox(height: 16),
              for (final field in TruthField.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DropdownButtonFormField<int>(
                    initialValue: _columns[field] ?? -1,
                    isExpanded: true,
                    menuMaxHeight: 320,
                    decoration: InputDecoration(
                      labelText: _fieldLabels[field],
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(value: -1, child: Text('不读取')),
                      for (var index = 0; index < headers.length; index++)
                        DropdownMenuItem(
                          value: index,
                          child: Text(
                            '${index + 1} · ${headers[index]}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      if (value == null || value < 0) {
                        _columns.remove(field);
                      } else {
                        _columns[field] = value;
                      }
                    }),
                  ),
                ),
              TextField(
                controller: _gpsOffset,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'GPST − UTC（秒）',
                  helperText: '用于 GPS 周/周内秒转换；示例数据为 18 秒。',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final offset = int.tryParse(_gpsOffset.text.trim());
            if (!_columns.containsKey(TruthField.latitude) ||
                !_columns.containsKey(TruthField.longitude) ||
                (!_columns.containsKey(TruthField.utcTime) &&
                    !(_columns.containsKey(TruthField.gpsWeek) &&
                        _columns.containsKey(TruthField.gpsSeconds))) ||
                offset == null ||
                offset < 0 ||
                offset > 60) {
              setState(() => _error = '请选择经纬度和完整时间列，并填写有效的 GPST − UTC 秒数。');
              return;
            }
            Navigator.pop(
              context,
              _TruthImportConfiguration(
                TruthColumnMapping(
                  columns: _columns,
                  delimiter: widget.preview.mapping.delimiter,
                ),
                offset,
              ),
            );
          },
          child: const Text('确认导入'),
        ),
      ],
    );
  }
}
