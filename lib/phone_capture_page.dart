import 'package:flutter/material.dart';
import 'phone_capture_service.dart';
import 'mobile_ui.dart';

class PhoneCapturePage extends StatefulWidget {
  const PhoneCapturePage({super.key, required this.onOpenDrawer, this.service});
  final VoidCallback onOpenDrawer;
  final PhoneCaptureService? service;
  @override
  State<PhoneCapturePage> createState() => _PhoneCapturePageState();
}

class _PhoneCapturePageState extends State<PhoneCapturePage> {
  late final service = widget.service ?? PhoneCaptureService();
  final selected = <String>{};
  int hz = 100;
  List<Map<String, dynamic>> files = [];
  @override
  void initState() {
    super.initState();
    service.listen();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final result = await PhoneCaptureService.sessions();
      if (mounted) setState(() => files = result);
    } catch (_) {
      /* Native capability errors are shown by the capture controls. */
    }
  }

  @override
  void dispose() {
    if (widget.service == null) service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final locked = service.recording || service.busy;
      final validSelection =
          selected.isNotEmpty && selected.every(service.available);
      return Scaffold(
        appBar: AppBar(
          title: const FittedBox(child: Text('手机数据采集')),
          leading: IconButton(
            tooltip: '打开导航',
            icon: const Icon(Icons.menu),
            onPressed: widget.onOpenDrawer,
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            MobileHero(
              title: service.recording ? '正在记录传感器数据' : '把手机变成采集终端',
              description:
                  service.state['message'] as String? ??
                  '先检测传感器，再选择采集内容。建议在室外检测 GNSS。',
              icon: Icons.sensors,
              status: MobileStatusChip(
                service.recording
                    ? '采集中'
                    : service.probing
                    ? '检测中'
                    : '准备采集',
                icon: service.recording
                    ? Icons.radio_button_checked
                    : Icons.sensors,
                emphasized: service.recording,
              ),
            ),
            if (service.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: MobileNotice(service.error!, error: true),
              ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: locked ? null : () => service.command('probe'),
                  icon: const Icon(Icons.sensors),
                  label: const Text('检测传感器'),
                ),
                FilledButton.icon(
                  onPressed:
                      locked ||
                          !service.probing ||
                          !service.timeReady ||
                          !validSelection
                      ? null
                      : () => service.command('start', {
                          'sensors': selected.toList(),
                          'hz': hz,
                        }),
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('开始采集'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      service.busy || (!service.probing && !service.recording)
                      ? null
                      : () async {
                          await service.command('stop');
                          await _refresh();
                        },
                  icon: const Icon(Icons.stop),
                  label: const Text('停止'),
                ),
              ],
            ),
            const MobileSectionTitle('采集内容', icon: Icons.tune),
            for (final (key, label, icon) in const [
              ('gnss', 'GNSS 原始观测', Icons.satellite_alt),
              ('accel', '加速度计', Icons.speed_outlined),
              ('gyro', '陀螺仪', Icons.screen_rotation_outlined),
              ('mag', '磁传感器', Icons.explore_outlined),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: MobilePanel(
                  padding: EdgeInsets.zero,
                  child: CheckboxListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    controlAffinity: ListTileControlAffinity.trailing,
                    secondary: MobileIconTile(
                      icon,
                      active: service.available(key),
                    ),
                    title: Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      service.detail(key),
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                    value: service.recording
                        ? (service.state['selected'] as List? ?? []).contains(
                            key,
                          )
                        : selected.contains(key),
                    onChanged: locked || !service.available(key)
                        ? null
                        : (v) => setState(() {
                            if (v == true) {
                              selected.add(key);
                            } else {
                              selected.remove(key);
                            }
                          }),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            DropdownButtonFormField<int>(
              initialValue: hz,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'IMU / 磁场请求采样率',
                prefixIcon: Icon(Icons.multiline_chart),
              ),
              items: [25, 50, 100, 200]
                  .map((v) => DropdownMenuItem(value: v, child: Text('$v Hz')))
                  .toList(),
              onChanged: locked
                  ? null
                  : (value) => setState(() => hz = value ?? 100),
            ),
            const SizedBox(height: 12),
            MobileNotice(
              service.timeReady
                  ? 'GNSS 时间已同步'
                  : '等待 GNSS 时间同步；仅采 IMU / 磁场也需要 GNSS 授时',
              icon: service.timeReady
                  ? Icons.check_circle_outline
                  : Icons.schedule,
            ),
            if (service.recording) ...[
              const MobileSectionTitle('已采集样本', icon: Icons.bar_chart_outlined),
              MobileMetrics(
                children: [
                  for (final (key, label, icon) in const [
                    ('gnss', 'GNSS', Icons.satellite_alt),
                    ('accel', '加速度', Icons.speed_outlined),
                    ('gyro', '角速度', Icons.screen_rotation_outlined),
                    ('mag', '磁场', Icons.explore_outlined),
                  ])
                    MobileMetric(
                      label: label,
                      value: '${(service.state['counts'] as Map?)?[key] ?? 0}',
                      icon: icon,
                    ),
                ],
              ),
            ],
            const MobileSectionTitle('存储路径', icon: Icons.folder_open_outlined),
            MobilePanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    service.state['path'] as String? ?? '检测后显示本地路径',
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  ),
                  const SizedBox(height: 12),
                  const Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      MobileStatusChip(
                        'GNSS · RTCM / CSV',
                        icon: Icons.satellite_alt,
                      ),
                      MobileStatusChip('IMU · BIN', icon: Icons.sensors),
                      MobileStatusChip(
                        '磁场 · BIN',
                        icon: Icons.explore_outlined,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '时间与采集说明：clock.csv、session.json\n停止后可分享；BIN 文件可在 IMU 批量解码中转换。',
                    style: TextStyle(fontSize: 12, height: 1.6),
                  ),
                  const ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('采集说明', style: TextStyle(fontSize: 14)),
                    children: [
                      Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          '保持手机坐标轴原始方向，不插值、不补零。载波相位由手机提供，缺失时标记无效。实际采样率由硬件决定。',
                          style: TextStyle(fontSize: 13, height: 1.6),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            MobileSectionTitle(
              '已保存的采集',
              icon: Icons.inventory_2_outlined,
              trailing: IconButton(
                tooltip: '刷新文件',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ),
            if (files.isEmpty)
              const MobileEmptyState(
                icon: Icons.snippet_folder_outlined,
                title: '还没有采集记录',
                message: '完成一次采集后，文件会显示在这里，方便查看和分享。',
              ),
            for (final session in files)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const MobileIconTile(Icons.folder_outlined),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                session['name'] as String,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          session['path'] as String,
                          style: const TextStyle(fontSize: 12, height: 1.6),
                        ),
                        TextButton.icon(
                          onPressed: locked
                              ? null
                              : () => service.command('share', {
                                  'paths': session['files'],
                                }),
                          icon: const Icon(Icons.share),
                          label: const Text('分享采集文件'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
        ),
      );
    },
  );
}
