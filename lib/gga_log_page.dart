import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'gga_log_service.dart';
import 'mobile_ui.dart';

class GgaLogPage extends StatefulWidget {
  const GgaLogPage({
    super.key,
    required this.service,
    required this.onOpenDrawer,
    required this.active,
  });
  final GgaLogService service;
  final VoidCallback onOpenDrawer;
  final bool active;

  @override
  State<GgaLogPage> createState() => _GgaLogPageState();
}

class _GgaLogPageState extends State<GgaLogPage> with WidgetsBindingObserver {
  List<GgaLogFile> _files = [];
  Timer? _refreshTimer;
  bool _loading = false;
  bool _busy = false;
  int _revision = -1;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updateVisibility();
  }

  @override
  void didUpdateWidget(covariant GgaLogPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _updateVisibility();
  }

  void _updateVisibility() {
    _refreshTimer?.cancel();
    if (!widget.active) return;
    unawaited(_refresh());
    // Refresh file metadata only while this page is visible and data has changed.
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_revision != widget.service.revision) unawaited(_refresh());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _updateVisibility();
    } else {
      _refreshTimer?.cancel();
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    _loading = true;
    final revision = widget.service.revision;
    try {
      final files = await widget.service.listFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _revision = revision;
        _error = null;
      });
    } catch (exception) {
      if (mounted) setState(() => _error = _errorText(exception));
    } finally {
      _loading = false;
    }
  }

  String _errorText(Object exception) => exception is PlatformException
      ? exception.message ?? '文件操作失败，请重试'
      : '文件操作失败：$exception';

  Future<void> _act(Future<void> Function() action, {String? deleted}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      if (deleted != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已删除 $deleted')));
      }
      await _refresh();
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_errorText(exception))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: 56,
      leading: IconButton(
        tooltip: '打开导航',
        icon: const Icon(Icons.menu),
        onPressed: widget.onOpenDrawer,
      ),
      title: const FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          '日志存储',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
      actions: [
        IconButton(
          tooltip: '刷新日志',
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const MobileHero(
            title: '每一段轨迹，都有记录',
            description: '收到的 GGA 自动按 UTC 日期保存，同一天持续追加到同一个文件。',
            icon: Icons.folder_open_outlined,
            status: MobileStatusChip('按日归档', icon: Icons.event_note_outlined),
          ),
          const SizedBox(height: 12),
          MobileMetrics(
            children: [
              MobileMetric(
                label: '日志文件',
                value: '${_files.length}',
                icon: Icons.description_outlined,
              ),
              const MobileMetric(
                label: '归档时区',
                value: 'UTC',
                icon: Icons.schedule,
              ),
            ],
          ),
          const MobileSectionTitle('保存路径', icon: Icons.folder_outlined),
          MobilePanel(
            child: SelectableText(
              widget.service.directoryPath ?? '正在准备存储目录…',
              style: const TextStyle(fontSize: 12, height: 1.6),
            ),
          ),
          if (widget.service.error != null || _error != null) ...[
            const SizedBox(height: 12),
            MobileNotice(widget.service.error ?? _error!, error: true),
          ],
          const MobileSectionTitle('日志文件', icon: Icons.inventory_2_outlined),
          if (_files.isEmpty)
            const MobileEmptyState(
              icon: Icons.description_outlined,
              title: '还没有 GGA 日志',
              message: '连接设备并接收消息后，日志会自动生成在这里。',
            ),
          for (final file in _files)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const MobileIconTile(Icons.description_outlined),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            file.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '修改时间（UTC）\n${DateFormat('yyyy-MM-dd HH:mm:ss').format(file.modified.toUtc())}',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Divider(height: 24),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () =>
                                    _act(() => widget.service.open(file.name)),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('打开'),
                        ),
                        TextButton.icon(
                          onPressed: _busy
                              ? null
                              : () =>
                                    _act(() => widget.service.share(file.name)),
                          icon: const Icon(Icons.share),
                          label: const Text('分享'),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                          onPressed: _busy
                              ? null
                              : () => _act(
                                  () => widget.service.delete(file.name),
                                  deleted: file.name,
                                ),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          const MobileNotice('删除当天日志后，后续收到的 GGA 会重新生成当天文件。'),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    super.dispose();
  }
}
