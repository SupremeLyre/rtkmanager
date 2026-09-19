import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class GgaLogFile {
  const GgaLogFile({required this.name, required this.modified});
  final String name;
  final DateTime modified;
}

/// One append-only file per UTC reception day, independent of the visible page.
class GgaLogService extends ChangeNotifier {
  GgaLogService({
    required Stream<String> messages,
    Future<Directory> Function()? directory,
    DateTime Function()? clock,
    MethodChannel? methods,
  }) : _directoryProvider = directory,
       _clock = clock ?? DateTime.now,
       _methods = methods ?? const MethodChannel('rtkmanager/gga_logs') {
    ready = _enqueue(_ensureDirectory).catchError(_reportError);
    _subscription = messages.listen(_record);
  }

  static final _filename = RegExp(r'^GGA\d{8}\.txt$');
  final Future<Directory> Function()? _directoryProvider;
  final DateTime Function() _clock;
  final MethodChannel _methods;
  late final StreamSubscription<String> _subscription;
  late final Future<void> ready;
  Future<void> _pending = Future.value();
  Directory? _directory;
  RandomAccessFile? _writer;
  String? _writerName;
  bool _disposed = false;
  String? error;
  int revision = 0;

  String? get directoryPath => _directory?.path;

  static String filenameFor(DateTime receivedAt) {
    final utc = receivedAt.toUtc();
    return 'GGA${utc.year.toString().padLeft(4, '0')}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}.txt';
  }

  // Serialize writes, rollover, reads and deletion so a deleted active file is
  // closed first and the next notification starts a fresh file at the same path.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _ensureDirectory() async {
    if (_directory != null) return;
    final provider = _directoryProvider;
    final directory = provider != null
        ? await provider()
        : Directory((await _methods.invokeMethod<String>('getLogDirectory'))!);
    await directory.create(recursive: true);
    _directory = directory;
    if (!_disposed) notifyListeners();
  }

  File _file(String name) {
    if (!_filename.hasMatch(name)) throw ArgumentError('无效的 GGA 日志文件名');
    return File('${_directory!.path}${Platform.pathSeparator}$name');
  }

  void _record(String sentence) {
    if (_disposed) return;
    // Capture the reception date before awaiting disk I/O, including at midnight.
    final name = filenameFor(_clock());
    unawaited(
      _enqueue<void>(() async {
        try {
          await _ensureDirectory();
          if (_writerName != name) {
            await _closeWriter();
            _writer = await _file(name).open(mode: FileMode.append);
            _writerName = name;
          }
          await _writer!.writeString('$sentence\r\n');
          revision++;
        } catch (exception) {
          _reportError(exception);
          // Recover before the next queued write touches the failed writer.
          await _closeWriter().catchError(_reportError);
        }
      }),
    );
  }

  void _reportError(Object exception) {
    if (_disposed) return;
    final message =
        '日志存储失败：${exception is PlatformException ? exception.message ?? exception.code : exception}';
    if (error == message) return;
    error = message;
    notifyListeners();
  }

  Future<void> _closeWriter() async {
    final writer = _writer;
    _writer = null;
    _writerName = null;
    if (writer == null) return;
    try {
      await writer.flush();
    } finally {
      await writer.close();
    }
  }

  Future<void> flush() => _enqueue<void>(() async {
    await _writer?.flush();
  }).catchError(_reportError);

  Future<List<GgaLogFile>> listFiles() => _enqueue(() async {
    await _ensureDirectory();
    await _writer?.flush();
    final result = <GgaLogFile>[];
    await for (final entity in _directory!.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is! File || !_filename.hasMatch(name)) continue;
      final stat = await entity.stat();
      if (stat.type == FileSystemEntityType.file) {
        result.add(GgaLogFile(name: name, modified: stat.modified));
      }
    }
    return result..sort((a, b) => b.name.compareTo(a.name));
  });

  Future<void> open(String name) => _launch('openLog', name);
  Future<void> share(String name) => _launch('shareLog', name);

  Future<void> _launch(String method, String name) => _enqueue(() async {
    await _ensureDirectory();
    await _writer?.flush();
    if (!await _file(name).exists()) {
      throw const FileSystemException('日志文件已不存在');
    }
    await _methods.invokeMethod<void>(method, {'name': name});
  });

  Future<void> delete(String name) => _enqueue(() async {
    await _ensureDirectory();
    final file = _file(name);
    if (_writerName == name) await _closeWriter();
    if (await file.exists()) await file.delete();
    revision++;
  });

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription.cancel());
    unawaited(_enqueue(_closeWriter).catchError((Object _) {}));
    super.dispose();
  }
}
