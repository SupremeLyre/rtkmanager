import 'package:flutter/material.dart';
import 'phone_capture_service.dart';
import 'app_ui.dart';

class PhoneCapturePage extends StatefulWidget {
  const PhoneCapturePage({
    super.key,
    required this.onOpenDrawer,
    this.service,
    this.onShowImu,
  });
  final VoidCallback onOpenDrawer;
  final PhoneCaptureService? service;
  final VoidCallback? onShowImu;
  @override
  State<PhoneCapturePage> createState() => _PhoneCapturePageState();
}

class _PhoneCapturePageState extends State<PhoneCapturePage> {
  late final service = widget.service ?? PhoneCaptureService();
  final selected = <String>{};
  int imuHz = 100;
  int magHz = 50;
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
        appBar: AppPageBar(title: '手机数据采集', onOpenDrawer: widget.onOpenDrawer),
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
                  key: const ValueKey('capture-probe'),
                  onPressed: locked ? null : () => service.command('probe'),
                  icon: const Icon(Icons.sensors),
                  label: const Text('检测传感器'),
                ),
                FilledButton.icon(
                  key: const ValueKey('capture-start'),
                  onPressed:
                      locked ||
                          !service.probing ||
                          !service.timeReady ||
                          !validSelection
                      ? null
                      : () => service.command('start', {
                          'sensors': selected.toList(),
                          'imuHz': imuHz,
                          'magHz': magHz,
                        }),
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('开始采集'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('capture-stop'),
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
                if (widget.onShowImu != null)
                  OutlinedButton.icon(
                    key: const ValueKey('capture-open-imu'),
                    onPressed: widget.onShowImu,
                    icon: const Icon(Icons.show_chart),
                    label: const Text('IMU 实时曲线'),
                  ),
              ],
            ),
            const MobileSectionTitle('采集内容', icon: Icons.tune),
            for (final (key, label, icon) in const [
              ('gnss', 'GNSS 原始观测', Icons.satellite_alt),
              ('imu', 'IMU（加速度计 + 陀螺仪）', Icons.sensors_outlined),
              ('mag', '磁传感器', Icons.explore_outlined),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: MobilePanel(
                  padding: EdgeInsets.zero,
                  child: CheckboxListTile(
                    key: ValueKey('capture-$key'),
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
              key: const ValueKey('imu-rate'),
              initialValue: imuHz,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'IMU 请求采样率',
                prefixIcon: Icon(Icons.multiline_chart),
              ),
              items: [25, 50, 100, 200]
                  .map((v) => DropdownMenuItem(value: v, child: Text('$v Hz')))
                  .toList(),
              onChanged: locked
                  ? null
                  : (value) => setState(() => imuHz = value ?? 100),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('mag-rate'),
              initialValue: magHz,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '磁力计请求采样率',
                prefixIcon: Icon(Icons.explore_outlined),
              ),
              items: [10, 25, 50, 100, 200]
                  .map((v) => DropdownMenuItem(value: v, child: Text('$v Hz')))
                  .toList(),
              onChanged: locked
                  ? null
                  : (value) => setState(() => magHz = value ?? 50),
            ),
            const SizedBox(height: 12),
            MobileNotice(
              [
                'IMU 与磁力计分别请求频率，以实测输出为准。',
                for (final (key, name) in const [
                  ('imu', 'IMU'),
                  ('mag', '磁力计'),
                ])
                  if (service.maxHz(key) != null)
                    '$name 硬件上限 ${service.maxHz(key)!.toStringAsFixed(0)} Hz',
                if (service.maxHz('mag') != null &&
                    magHz > service.maxHz('mag')!)
                  '磁力计请求超过硬件上限，将按硬件上限采集。',
              ].join('\n'),
              icon: Icons.speed_outlined,
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
                    ('imu', '六轴 IMU', Icons.sensors_outlined),
                    ('mag', '磁场', Icons.explore_outlined),
                  ])
                    MobileMetric(
                      label: label,
                      value: '${(service.state['counts'] as Map?)?[key] ?? 0}',
                      icon: icon,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              MobileNotice(
                '实测输出：IMU ${service.rate('imu').toStringAsFixed(1)} Hz · 磁场 ${service.rate('mag').toStringAsFixed(1)} Hz\n'
                '原始输入：加速度 ${service.rate('accel').toStringAsFixed(1)} Hz · 陀螺仪 ${service.rate('gyro').toStringAsFixed(1)} Hz\n'
                '未配对样本 ${service.state['unpairedImuSamples'] ?? 0} 条',
                icon: Icons.monitor_heart_outlined,
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
                          '加速度与角速度按时间一对一配成六轴 IMU，采用陀螺仪时间；原始时间及配对偏差保存在 CSV。保持手机坐标轴原始方向，不插值、不补零。实际采样率由硬件决定。',
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
