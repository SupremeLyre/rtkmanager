import 'package:flutter/material.dart';
import 'mqtt_position_service.dart';

class MqttConnectionPanel extends StatefulWidget {
  const MqttConnectionPanel({
    super.key,
    required this.service,
    required this.onReceive,
  });
  final MqttPositionService service;
  final VoidCallback onReceive;

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
  }

  @override
  void dispose() {
    for (final controller in [_host, _port, _topic, _username, _password]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) {
      final service = widget.service;
      return SingleChildScrollView(
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
                  const Icon(Icons.cloud_download_outlined),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'MQTT 接收',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭 MQTT 设置',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(
                '${service.statusLabel} · ${service.tracks.length} 台设备 · 收到 ${service.receivedMessages} 条消息',
              ),
              if (service.ignoredMessages > 0)
                Text('已忽略 ${service.ignoredMessages} 条无效、重复或过期消息'),
              if (service.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    service.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('mqtt-host'),
                controller: _host,
                enabled: !service.isActive,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: '域名或 IP',
                ),
                validator: (value) =>
                    value == null ||
                        value.trim().isEmpty ||
                        value.contains('://') ||
                        value.contains('/')
                    ? '请输入域名或 IP，不含协议前缀和路径'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mqtt-port'),
                controller: _port,
                enabled: !service.isActive,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '端口'),
                validator: (value) {
                  final port = int.tryParse(value ?? '');
                  return port == null || port < 1 || port > 65535
                      ? '端口范围为 1–65535'
                      : null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mqtt-topic'),
                controller: _topic,
                enabled: !service.isActive,
                decoration: const InputDecoration(labelText: '订阅主题'),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入订阅主题' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mqtt-username'),
                controller: _username,
                enabled: !service.isActive,
                decoration: const InputDecoration(labelText: '用户名（可选）'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('mqtt-password'),
                controller: _password,
                enabled: !service.isActive,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '密码（可选）',
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? '隐藏密码' : '显示密码',
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword ? Icons.visibility_off : Icons.visibility,
                    ),
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('TLS 加密'),
                value: _tls,
                onChanged: service.isActive
                    ? null
                    : (value) => setState(() {
                        _tls = value;
                        if (_port.text == '1883' && value) _port.text = '8883';
                        if (_port.text == '8883' && !value) _port.text = '1883';
                      }),
              ),
              const Text('按 device_id 自动建立设备图层；每台设备固定一种颜色。账号仅保留在本次运行中。'),
              const SizedBox(height: 8),
              Text(service.cacheDescription),
              Text(
                '已保存 ${service.archive.savedRecords} 条 · 待写 ${service.archive.pendingRecords} 条',
              ),
              if (service.archive.error != null)
                Text(
                  service.archive.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const Text('可从“数据来源 → MQTT 接收日志”查看文件，安卓端支持分享。'),
              Text(
                '当前缓存 ${service.cachedPoints} 点 · 已淘汰 ${service.evictedPoints} 点 / ${service.evictedDevices} 台设备',
              ),
              const SizedBox(height: 16),
              if (service.isActive)
                OutlinedButton.icon(
                  onPressed: service.disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开连接'),
                )
              else
                FilledButton.icon(
                  onPressed: () {
                    if (!_form.currentState!.validate()) return;
                    widget.onReceive();
                    service.connect(
                      MqttPositionSettings(
                        host: _host.text.trim(),
                        port: int.parse(_port.text),
                        topic: _topic.text.trim(),
                        username: _username.text,
                        password: _password.text,
                        tls: _tls,
                      ),
                    );
                  },
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: const Text('连接并接收'),
                ),
            ],
          ),
        ),
      );
    },
  );
}
