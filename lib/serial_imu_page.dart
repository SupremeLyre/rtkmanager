import 'package:flutter/material.dart';
import 'imu_visualization_page.dart';
import 'serial_service.dart';

class SerialImuPage extends StatefulWidget {
  const SerialImuPage({
    super.key,
    required this.onOpenDrawer,
    required this.onOpenSerial,
    required this.active,
  });
  final VoidCallback onOpenDrawer;
  final VoidCallback onOpenSerial;
  final bool active;
  @override
  State<SerialImuPage> createState() => _SerialImuPageState();
}

class _SerialImuPageState extends State<SerialImuPage> {
  SerialService? _selected;
  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<List<SerialService>>(
        valueListenable: SerialService.connectedServices,
        builder: (context, ports, _) {
          final source = ports.contains(_selected)
              ? _selected!
              : ports.isNotEmpty
              ? ports.first
              : SerialService();
          return ImuVisualizationPage(
            dataStream: source.imuDataStream,
            sourceLabel: '串口 · ${source.currentPortName ?? '等待连接'}',
            emptyMessage: '先在“串口调试助手”中连接输出 IMU 二进制帧的设备。连接后自动解析，选择串口即可查看三轴曲线。',
            onOpenDrawer: widget.onOpenDrawer,
            onOpenSource: widget.onOpenSerial,
            active: widget.active,
            sourceControl: ports.isEmpty
                ? null
                : DropdownButtonFormField<SerialService>(
                    key: ValueKey(source),
                    initialValue: source,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '数据串口'),
                    items: [
                      for (final port in ports)
                        DropdownMenuItem(
                          value: port,
                          child: Text(port.currentPortName ?? '主串口'),
                        ),
                    ],
                    onChanged: (value) => setState(() => _selected = value),
                  ),
          );
        },
      );
}
