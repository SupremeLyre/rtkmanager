import 'package:flutter/material.dart';

import 'gnss_ble_service.dart';
import 'gga_log_service.dart';
import 'app_ui.dart';

class DeviceConnectionPage extends StatefulWidget {
  const DeviceConnectionPage({
    super.key,
    required this.service,
    required this.onOpenDrawer,
    required this.onShowPositioning,
    this.importingFile = false,
    this.logs,
  });

  final GnssBleService service;
  final VoidCallback onOpenDrawer;
  final VoidCallback onShowPositioning;
  final bool importingFile;
  final GgaLogService? logs;

  @override
  State<DeviceConnectionPage> createState() => _DeviceConnectionPageState();
}

class _DeviceConnectionPageState extends State<DeviceConnectionPage> {
  final _search = TextEditingController();
  bool _showUnnamed = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppPageBar(title: '设备连接', onOpenDrawer: widget.onOpenDrawer),
    body: AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        final service = widget.service;
        final logs = widget.logs;
        final importingFile = widget.importingFile;
        final busy = service.scanning || service.requestingScan;
        final connected = service.connection == GnssBleConnection.connected;
        final devices = service.filteredDevices(
          query: _search.text,
          includeUnnamed: _showUnnamed,
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (logs != null)
              AnimatedBuilder(
                animation: logs,
                builder: (context, _) => logs.error == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: MobileNotice(logs.error!, error: true),
                      ),
              ),
            if (service.error != null) ...[
              MobileNotice(service.error!, error: true),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: service.openSettings,
                  child: const Text('应用权限设置'),
                ),
              ),
            ],
            MobileHero(
              title: connected
                  ? '设备已就绪'
                  : service.isActive
                  ? '正在建立连接'
                  : '连接你的 GNSS 设备',
              description: connected
                  ? service.ggaCount == 0
                        ? '等待 GGA 消息'
                        : '已接收 ${service.ggaCount} 条 GGA'
                  : '扫描附近的 BLE 蓝牙设备，选择设备后校验 GNSS 协议，校验通过即可接收定位消息。',
              icon: connected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              status: MobileStatusChip(
                connected
                    ? '已连接'
                    : service.isActive
                    ? '校验中'
                    : busy
                    ? '扫描中'
                    : '未连接设备',
                icon: connected ? Icons.check_circle_outline : Icons.bluetooth,
                emphasized: connected || busy,
              ),
              action: service.isActive
                  ? connected
                        ? FilledButton.icon(
                            onPressed: widget.onShowPositioning,
                            icon: const Icon(Icons.map_outlined),
                            label: const Text('查看定位结果'),
                          )
                        : const MobileNotice(
                            '正在连接并校验设备…',
                            icon: Icons.bluetooth_searching,
                          )
                  : FilledButton.icon(
                      onPressed: importingFile
                          ? null
                          : busy
                          ? service.stopScan
                          : service.startScan,
                      icon: Icon(busy ? Icons.stop : Icons.search),
                      label: Text(busy ? '停止扫描' : '扫描设备'),
                    ),
            ),
            if (service.isActive) ...[
              const MobileSectionTitle(
                '当前设备',
                icon: Icons.developer_board_outlined,
              ),
              MobilePanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: MobileIconTile(
                        connected
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth_searching,
                      ),
                      title: Text(service.device?.name ?? 'GNSS 设备'),
                      subtitle: Text(service.device?.id ?? ''),
                    ),
                    OutlinedButton(
                      onPressed: service.disconnect,
                      child: Text(connected ? '断开连接' : '取消连接'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              MobileMetrics(
                children: [
                  MobileMetric(
                    label: '已接收 GGA',
                    value: '${service.ggaCount}',
                    icon: Icons.downloading_outlined,
                  ),
                  MobileMetric(
                    label: '数据状态',
                    value: connected
                        ? service.ggaCount == 0
                              ? '等待消息'
                              : '已接收'
                        : '校验中',
                    icon: Icons.satellite_alt,
                  ),
                ],
              ),
              if (service.latestGga != null) ...[
                const MobileSectionTitle('最近一条 GGA', icon: Icons.code),
                MobilePanel(
                  child: SelectableText(
                    service.latestGga!,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.7,
                      fontFamily: 'SourceCodePro',
                    ),
                  ),
                ),
              ],
            ] else ...[
              if (importingFile) ...[
                const SizedBox(height: 12),
                const MobileNotice('正在导入文件，请完成后再连接设备。'),
              ],
              MobileSectionTitle(
                '附近的设备',
                icon: Icons.radar,
                trailing: Flexible(
                  child: MobileStatusChip(
                    '${devices.length} / ${service.devices.length} 台',
                    icon: Icons.bluetooth,
                  ),
                ),
              ),
              MobilePanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: '设备名称或蓝牙地址',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                icon: const Icon(Icons.clear),
                                onPressed: () => setState(_search.clear),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilterChip(
                      label: const Text('显示未命名设备'),
                      selected: _showUnnamed,
                      avatar: const Icon(Icons.bluetooth_searching, size: 18),
                      onSelected: (value) =>
                          setState(() => _showUnnamed = value),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _search.text.trim().isEmpty
                          ? _showUnnamed
                                ? '已显示全部扫描结果。'
                                : '默认隐藏未命名设备，找不到时可开启显示。'
                          : '正在全部扫描结果中搜索，包括未命名设备。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(),
                ),
              if (devices.isEmpty)
                MobileEmptyState(
                  icon: Icons.radar,
                  title: service.devices.isEmpty
                      ? busy
                            ? '正在查找设备…'
                            : '等待发现设备'
                      : '没有匹配的设备',
                  message: service.devices.isEmpty
                      ? '请确认设备已开机、在附近，且正在广播。'
                      : _search.text.trim().isNotEmpty
                      ? '试试设备名称的一部分或蓝牙地址，或清除搜索。'
                      : '已发现 ${service.devices.length} 台未命名设备，可开启上方开关查看。',
                ),
              for (final device in devices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    key: ValueKey('ble-device-${device.id}'),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      leading: const MobileIconTile(Icons.bluetooth),
                      title: Text(device.name),
                      subtitle: Text('${device.id} · ${device.rssi} dBm'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: importingFile
                          ? null
                          : () => service.connect(device),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              const MobileNotice(
                '连接后可在「定位结果」查看轨迹，在「日志存储」管理自动保存的 GGA 文件。',
                icon: Icons.route_outlined,
              ),
            ],
            const SizedBox(height: 16),
          ],
        );
      },
    ),
  );
}
