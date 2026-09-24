import 'package:flutter/material.dart';
import 'app_ui.dart';
import 'mqtt_position_service.dart';

class MqttConnectionPanel extends StatefulWidget {
  const MqttConnectionPanel({
    super.key,
    required this.service,
    required this.onReceive,
    required this.onOpenLogs,
  });
  final MqttPositionService service;
  final VoidCallback onReceive;
  final VoidCallback onOpenLogs;

  @override
  State<MqttConnectionPanel> createState() => _MqttConnectionPanelState();
}

class _MqttConnectionPanelState extends State<MqttConnectionPanel> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _topic;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late bool _tls;
  late final bool _expandSecurity;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.service.settings;
    _host = TextEditingController(text: settings.host);
    _port = TextEditingController(text: '${settings.port}');
    _topic = TextEditingController(text: settings.topic);
    _username = TextEditingController(text: settings.username);
    _password = TextEditingController(text: settings.password);
    _tls = settings.tls;
    _expandSecurity =
        settings.username.isNotEmpty ||
        settings.password.isNotEmpty ||
        settings.tls;
  }

  @override
  void dispose() {
    for (final controller in [_host, _port, _topic, _username, _password]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _connect() {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    widget.onReceive();
    widget.service.connect(
      MqttPositionSettings(
        host: _host.text.trim(),
        port: int.parse(_port.text),
        topic: _topic.text.trim(),
        username: _username.text,
        password: _password.text,
        tls: _tls,
      ),
    );
  }

  InputDecoration _decoration(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: ExcludeSemantics(child: Icon(icon, size: 20)),
  );

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 16,
      runSpacing: 4,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );

  Widget _counts(MqttPositionService service) => MobilePanel(
    padding: const EdgeInsets.all(12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = (constraints.maxWidth / (80 * scale)).floor().clamp(
          1,
          3,
        );
        final entries = [
          (Icons.devices_outlined, '设备', service.tracks.length, '台设备'),
          (Icons.downloading_outlined, '已接收', service.receivedMessages, '条消息'),
          (Icons.save_outlined, '已落盘', service.archive.savedRecords, '条记录'),
        ];
        return Wrap(
          spacing: 8,
          runSpacing: 12,
          children: [
            for (final (icon, label, value, unit) in entries)
              SizedBox(
                width: (constraints.maxWidth - (columns - 1) * 8) / columns,
                child: Tooltip(
                  message: '$label $value $unit',
                  child: Semantics(
                    label: '$label $value $unit',
                    excludeSemantics: true,
                    child: columns == 1
                        ? Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    icon,
                                    size: 18,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                _countLabel(value),
                                textAlign: TextAlign.end,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                icon,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _countLabel(value),
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                label,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );

  String _countLabel(int value) => value < 10000
      ? '$value'
      : value < 100000000
      ? '${(value / 10000).toStringAsFixed(1)}万'
      : '${(value / 100000000).toStringAsFixed(1)}亿';

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) {
      final service = widget.service;
      final colors = Theme.of(context).colorScheme;
      final animation = MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null;
      final statusIcon = switch (service.connection) {
        MqttPositionConnection.connected => Icons.check_circle_outline,
        MqttPositionConnection.connecting ||
        MqttPositionConnection.reconnecting => Icons.sync,
        MqttPositionConnection.failed => Icons.error_outline,
        MqttPositionConnection.disconnected => Icons.cloud_off_outlined,
      };
      return SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const MobileIconTile(Icons.cloud_download_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'MQTT 接收',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Semantics(
                          liveRegion: true,
                          child: Row(
                            children: [
                              ExcludeSemantics(
                                child: Icon(
                                  statusIcon,
                                  size: 16,
                                  color: service.error == null
                                      ? colors.primary
                                      : colors.error,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  service.statusLabel,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: service.error == null
                                        ? colors.onSurfaceVariant
                                        : colors.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭 MQTT 设置',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _counts(service),
              const SizedBox(height: 20),
              AppFieldPair(
                first: TextFormField(
                  key: const ValueKey('mqtt-host'),
                  controller: _host,
                  enabled: !service.isActive,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  decoration: _decoration(
                    '服务器地址',
                    Icons.dns_outlined,
                  ).copyWith(hintText: '域名或 IP', errorMaxLines: 3),
                  validator: (value) =>
                      value == null ||
                          value.trim().isEmpty ||
                          value.contains('://') ||
                          value.contains('/')
                      ? '请输入域名或 IP，不含协议前缀和路径'
                      : null,
                ),
                second: TextFormField(
                  key: const ValueKey('mqtt-port'),
                  controller: _port,
                  enabled: !service.isActive,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  decoration: _decoration('端口', Icons.tag),
                  validator: (value) {
                    final port = int.tryParse(value ?? '');
                    return port == null || port < 1 || port > 65535
                        ? '端口范围为 1–65535'
                        : null;
                  },
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mqtt-topic'),
                controller: _topic,
                enabled: !service.isActive,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                decoration: _decoration('订阅主题', Icons.topic_outlined),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入订阅主题' : null,
              ),
              const SizedBox(height: 8),
              ExpansionTile(
                key: const ValueKey('mqtt-security'),
                initiallyExpanded: _expandSecurity,
                maintainState: true,
                expansionAnimationStyle: animation,
                tilePadding: EdgeInsets.zero,
                shape: const Border(),
                collapsedShape: const Border(),
                leading: ExcludeSemantics(
                  child: Icon(
                    Icons.shield_outlined,
                    size: 20,
                    color: colors.primary,
                  ),
                ),
                title: const Text(
                  '账号与安全',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                children: [
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const ValueKey('mqtt-username'),
                    controller: _username,
                    enabled: !service.isActive,
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    decoration: _decoration('用户名（可选）', Icons.person_outline),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('mqtt-password'),
                    controller: _password,
                    enabled: !service.isActive,
                    obscureText: !_showPassword,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: _decoration('密码（可选）', Icons.key_outlined)
                        .copyWith(
                          suffixIcon: IconButton(
                            tooltip: _showPassword ? '隐藏密码' : '显示密码',
                            onPressed: () =>
                                setState(() => _showPassword = !_showPassword),
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('TLS 加密', style: TextStyle(fontSize: 14)),
                    value: _tls,
                    onChanged: service.isActive
                        ? null
                        : (value) => setState(() {
                            _tls = value;
                            if (_port.text == '1883' && value) {
                              _port.text = '8883';
                            }
                            if (_port.text == '8883' && !value) {
                              _port.text = '1883';
                            }
                          }),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '账号仅用于本次运行',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
              if (service.error != null) ...[
                MobileNotice(service.error!, error: true),
                const SizedBox(height: 12),
              ],
              if (service.archive.error != null) ...[
                MobileNotice(service.archive.error!, error: true),
                const SizedBox(height: 12),
              ],
              if (service.isActive)
                OutlinedButton.icon(
                  onPressed: service.disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开连接'),
                )
              else
                FilledButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('连接并接收'),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: widget.onOpenLogs,
                  icon: const Icon(Icons.folder_open_outlined, size: 20),
                  label: const Text('接收日志'),
                ),
              ),
              const Divider(height: 16),
              ExpansionTile(
                key: const ValueKey('mqtt-diagnostics'),
                expansionAnimationStyle: animation,
                tilePadding: EdgeInsets.zero,
                shape: const Border(),
                collapsedShape: const Border(),
                leading: ExcludeSemantics(
                  child: Icon(
                    Icons.analytics_outlined,
                    color: colors.onSurfaceVariant,
                    size: 20,
                  ),
                ),
                title: const Text('接收详情', style: TextStyle(fontSize: 14)),
                children: [
                  _detail(
                    '地图缓存',
                    '${service.cachedPoints} / ${service.maxTotalPoints} 点',
                  ),
                  _detail('单设备上限', '${service.maxPointsPerDevice} 点'),
                  _detail('设备上限', '${service.maxDevices} 台'),
                  _detail(
                    '已移出缓存',
                    '${service.evictedPoints} 点 · ${service.evictedDevices} 台',
                  ),
                  _detail('已过滤消息', '${service.ignoredMessages} 条'),
                  _detail('待写入', '${service.archive.pendingRecords} 条'),
                  _detail('未能保存', '${service.archive.droppedRecords} 条'),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('清除地图缓存不会删除日志', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
