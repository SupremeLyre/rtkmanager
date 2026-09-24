import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Append-only daily JSONL files with a bounded, serialised disk-write queue.
class MqttPositionArchive extends ChangeNotifier {
  MqttPositionArchive({
    Future<Directory> Function()? directory,
    this.maxPendingRecords = 2000,
  }) : _directoryProvider = directory,
       assert(maxPendingRecords > 0);
  final Future<Directory> Function()? _directoryProvider;
  final int maxPendingRecords;
  static const _methods = MethodChannel('rtkmanager/gga_logs');
  final ListQueue<(String, String)> _pending = ListQueue();
  Future<void>? _writing;
  Future<void>? _closing;
  Timer? _retry;
  Directory? _directory;
  bool _disposed = false;
  int savedRecords = 0;
  int droppedRecords = 0;
  int get pendingRecords => _pending.length;
  String? error;
  String? get directoryPath => _directory?.path;

  static String filenameFor(DateTime time) {
    final utc = time.toUtc();
    return 'MQTT${utc.year.toString().padLeft(4, '0')}${utc.month.toString().padLeft(2, '0')}${utc.day.toString().padLeft(2, '0')}.jsonl';
  }

  void record(Map<String, Object?> record, DateTime receivedAt) {
    if (_closing != null || _disposed) return;
    if (_pending.length >= maxPendingRecords) {
      droppedRecords++;
      error = '磁盘写入积压，已有 $droppedRecords 条记录未能保存，请检查存储空间。';
      notifyListeners();
      return;
    }
    _pending.add((filenameFor(receivedAt), '${jsonEncode(record)}\n'));
    if (_writing == null && _retry == null) unawaited(_startWriting());
  }

  Future<Directory> _ensureDirectory() async {
    if (_directory != null) return _directory!;
    final Directory directory;
    if (_directoryProvider != null) {
      directory = await _directoryProvider();
    } else if (Platform.isAndroid) {
      directory = Directory(
        (await _methods.invokeMethod<String>('getMqttLogDirectory'))!,
      );
    } else {
      directory = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/RTKManager/MQTT',
      );
    }
    await directory.create(recursive: true);
    _directory = directory;
    return directory;
  }

  Future<void> _startWriting() =>
      _writing ??= _drain().whenComplete(() => _writing = null);

  Future<void> _drain() async {
    try {
      final directory = await _ensureDirectory();
      while (_pending.isNotEmpty) {
        final name = _pending.first.$1;
        final batch = _pending
            .take(128)
            .takeWhile((entry) => entry.$1 == name)
            .toList();
        final writer = await File(
          '${directory.path}/$name',
        ).open(mode: FileMode.append);
        try {
          final originalLength = await writer.length();
          try {
            await writer.writeString(batch.map((entry) => entry.$2).join());
            await writer.flush();
          } catch (_) {
            // A partial append must not leave broken JSON before retrying the batch.
            await writer.truncate(originalLength);
            rethrow;
          }
        } finally {
          await writer.close();
        }
        for (var i = 0; i < batch.length; i++) {
          _pending.removeFirst();
        }
        savedRecords += batch.length;
        error = droppedRecords == 0 ? null : '$droppedRecords 条记录因写入积压未能保存。';
        if (!_disposed) notifyListeners();
      }
    } catch (_) {
      error = 'MQTT 日志写入失败，请检查存储空间和目录权限；待写数据将有界保留并重试。';
      if (!_disposed) notifyListeners();
      if (_closing == null && !_disposed) {
        _retry = Timer(const Duration(seconds: 5), () {
          _retry = null;
          unawaited(_startWriting());
        });
      }
    }
  }

  Future<void> flush() async {
    _retry?.cancel();
    _retry = null;
    if (_writing != null) await _writing;
    if (_pending.isNotEmpty) await _startWriting();
  }

  Future<List<File>> recentFiles() async {
    await flush();
    final directory = await _ensureDirectory();
    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is! File ||
          !RegExp(r'MQTT\d{8}\.jsonl$').hasMatch(entity.path)) {
        continue;
      }
      files.add(entity);
      files.sort((a, b) => b.path.compareTo(a.path));
      if (files.length > 60) files.removeLast();
    }
    return files;
  }

  Future<void> share(File file) async {
    await flush();
    await _methods.invokeMethod<void>('shareMqttLog', {
      'name': file.uri.pathSegments.last,
    });
  }

  Future<void> close() => _closing ??= _finish();
  Future<void> _finish() async {
    await flush();
    dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retry?.cancel();
    _retry = null;
    unawaited(close());
    super.dispose();
  }
}
