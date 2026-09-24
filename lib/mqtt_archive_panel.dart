import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'mqtt_position_archive.dart';

class MqttArchivePanel extends StatefulWidget {
  const MqttArchivePanel({super.key, required this.archive});
  final MqttPositionArchive archive;
  @override
  State<MqttArchivePanel> createState() => _MqttArchivePanelState();
}

class _MqttArchivePanelState extends State<MqttArchivePanel> {
  late Future<List<File>> _files = widget.archive.recentFiles();

  Future<void> _share(File file) async {
    try {
      await widget.archive.share(file);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法分享日志，请检查文件是否存在。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.folder_open_outlined),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'MQTT 接收日志',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '刷新日志',
              onPressed: () =>
                  setState(() => _files = widget.archive.recentFiles()),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '关闭接收日志',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const Text('按接收日期（UTC）追加 JSONL 文件。清除地图缓存不会删除日志。显示最近 60 个文件。'),
        const SizedBox(height: 8),
        Expanded(
          child: FutureBuilder<List<File>>(
            future: _files,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('无法读取日志目录，请检查存储空间和权限。'));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final files = snapshot.data!;
              return ListView(
                children: [
                  SelectableText(widget.archive.directoryPath ?? ''),
                  if (!Platform.isAndroid)
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: widget.archive.directoryPath ?? ''),
                      ),
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('复制目录路径'),
                    ),
                  if (files.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('收到有效 GGA 后自动保存日志。'),
                    ),
                  for (final file in files)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined),
                      title: Text(file.uri.pathSegments.last),
                      trailing: IconButton(
                        tooltip: Platform.isAndroid ? '分享日志' : '复制文件路径',
                        onPressed: Platform.isAndroid
                            ? () => _share(file)
                            : () => Clipboard.setData(
                                ClipboardData(text: file.path),
                              ),
                        icon: Icon(
                          Platform.isAndroid
                              ? Icons.share_outlined
                              : Icons.copy,
                          size: 20,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    ),
  );
}
