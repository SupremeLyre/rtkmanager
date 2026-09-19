import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'imu_data_parser.dart';
import 'phone_capture_service.dart';
import 'mobile_ui.dart';

class FileItem {
  final String path;
  String status;
  double progress;
  bool isSelected;
  String? outputPath;
  FileItem({
    required this.path,
    this.status = '等待解码',
    this.progress = 0.0,
    this.isSelected = false,
  });
}

class ImuBatchDecodePage extends StatefulWidget {
  final VoidCallback onOpenDrawer;

  const ImuBatchDecodePage({super.key, required this.onOpenDrawer});

  @override
  State<ImuBatchDecodePage> createState() => _ImuBatchDecodePageState();
}

class _ImuBatchDecodePageState extends State<ImuBatchDecodePage> {
  final List<FileItem> _files = [];
  String? _outputDir;
  bool _isDecoding = false;

  // 设置项
  bool _useTidCompensation = !Platform.isAndroid;
  bool _outputEuler = false;
  bool _outputQuat = false;
  bool _outputPos = false;
  bool _outputVel = false;
  bool _outputStatus = false;
  bool _outputTemp = false;
  bool _outputTid = false;
  bool _decodeOnlyNavigationFrames = !Platform.isAndroid;
  bool _outputMag = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      // A failed initialization is reported when decoding is requested.
      _prepareOutputDirectory().catchError((Object _) {});
    }
  }

  Future<void> _prepareOutputDirectory() async {
    final path = await PhoneCaptureService.channel.invokeMethod<String>(
      'decodeDirectory',
    );
    if (mounted) setState(() => _outputDir = path);
  }

  Future<void> _pickCapture() async {
    try {
      final sessions = await PhoneCaptureService.sessions();
      if (!mounted) return;
      final paths = await showDialog<List<String>>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('选择手机采集'),
          children: [
            if (sessions.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('尚无采集文件')),
            for (final session in sessions)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(
                  context,
                  (session['files'] as List)
                      .cast<String>()
                      .where((p) => p.endsWith('.bin'))
                      .toList(),
                ),
                child: Text(session['name'] as String),
              ),
          ],
        ),
      );
      if (!mounted || paths == null) return;
      setState(() {
        _decodeOnlyNavigationFrames = false;
        _useTidCompensation = false;
        for (final path in paths) {
          if (!_files.any((f) => f.path == path)) {
            _files.add(FileItem(path: path));
          }
          if (path.endsWith('mag.bin')) _outputMag = true;
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('读取采集文件失败：$e')));
      }
    }
  }

  bool _hasNavigationPayload(ImuData data) {
    return data.lat != null ||
        data.lon != null ||
        data.alt != null ||
        data.ve != null ||
        data.vn != null ||
        data.vu != null ||
        data.fusionState != null ||
        data.gnssState != null ||
        data.pitch != null ||
        data.roll != null ||
        data.yaw != null ||
        data.q0 != null ||
        data.q1 != null ||
        data.q2 != null ||
        data.q3 != null;
  }

  Future<void> _pickFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (result != null && mounted) {
      setState(() {
        for (var file in result.paths) {
          if (file != null) {
            // Check if already exist to prevent duplicates if preferred
            if (!_files.any((f) => f.path == file)) {
              _files.add(FileItem(path: file));
            }
          }
        }
      });
    }
  }

  Future<void> _pickOutputDir() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory != null && mounted) {
      setState(() {
        _outputDir = selectedDirectory;
      });
    }
  }

  Future<void> _startDecode() async {
    if (_isDecoding || _files.isEmpty) return;
    if (Platform.isAndroid && _outputDir == null) {
      try {
        await _prepareOutputDirectory();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('输出目录不可用：$e')));
        }
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _isDecoding = true;
    });

    for (var item in _files) {
      if (item.status == '完成') continue;

      setState(() {
        item.status = '解码中...';
        item.progress = 0.0;
      });

      IOSink? openedSink;
      try {
        final parser = ImuDataParser();
        final file = File(item.path);
        final totalBytes = await file.length();
        int processedBytes = 0;
        int lastFlushBytes = 0;

        final lastSep = item.path.lastIndexOf(Platform.pathSeparator);
        final fileName = lastSep != -1
            ? item.path.substring(lastSep + 1)
            : item.path;

        final outDir = _outputDir ?? file.parent.path;
        final outputName =
            Platform.isAndroid && file.parent.path.contains('Capture_')
            ? '${file.parent.path.split(Platform.pathSeparator).last}_$fileName.csv'
            : '$fileName.csv';
        final outPath = '$outDir${Platform.pathSeparator}$outputName';
        final outFile = File(outPath);

        final sink = outFile.openWrite();
        openedSink = sink;
        final outputBuffer = StringBuffer();

        String header = _decodeOnlyNavigationFrames
            ? "GPSWeek,GPSSow"
            : "GPSWeek,GPSSow,gx,gy,gz,ax,ay,az";
        if (_outputTid) header += ",tid";
        if (_outputEuler) header += ",pitch,roll,yaw";
        if (_outputQuat) header += ",q0,q1,q2,q3";
        if (_outputPos) header += ",lat,lon,alt";
        if (_outputVel) header += ",ve,vn,vu";
        if (_outputStatus) header += ",fusionState,gnssState";
        if (_outputTemp) header += ",tempImu";
        if (_outputMag) header += ",mx_uT,my_uT,mz_uT";
        outputBuffer.writeln(header);

        String f(double? val) {
          return val?.toStringAsFixed(6).padLeft(10) ?? '';
        }

        bool isCompensating = false;
        int recoveryFrames = 0;
        int lastTid = -1;
        DateTime? lastOrigDt;
        DateTime? lastCompDt;

        await for (final chunk in file.openRead()) {
          parser.parseData(chunk, (imuData) {
            final bool hasRawImuFrame = imuData.hasRawImu;
            final bool hasNavPayload = _hasNavigationPayload(imuData);
            if (_decodeOnlyNavigationFrames) {
              if (!hasNavPayload && !(_outputMag && imuData.hasMag)) return;
            } else {
              // 导航结果可能延迟独立到达，不能将缺失的六轴数据补零输出。
              if (!hasRawImuFrame && !(_outputMag && imuData.hasMag)) return;
            }

            final ImuData outputData = imuData;

            int year = outputData.utcYear ?? 0;
            int month = outputData.utcMonth ?? 0;
            int day = outputData.utcDay ?? 0;
            int hour = outputData.utcHour ?? 0;
            int min = outputData.utcMin ?? 0;
            int sec = outputData.utcSec ?? 0;
            int msec = outputData.utcDateTimeMsec;
            int usec = outputData.utcDateTimeUsec;

            final hasGpsTime =
                outputData.gpsWeek != null && outputData.gpsTowNanos != null;
            if (!hasGpsTime &&
                (year < 1980 ||
                    month < 1 ||
                    month > 12 ||
                    day < 1 ||
                    day > 31)) {
              return;
            }

            DateTime origDt = DateTime.utc(
              year,
              month,
              day,
              hour,
              min,
              sec,
              msec,
              usec,
            );
            DateTime compDt = origDt;

            if (hasRawImuFrame &&
                !hasGpsTime &&
                _useTidCompensation &&
                lastTid != -1 &&
                lastOrigDt != null &&
                lastCompDt != null) {
              int currentTid = imuData.tid ?? 0;
              int diffTid = (currentTid - lastTid) % 60000;
              if (diffTid < 0) diffTid += 60000;

              double elapsedSec = diffTid / 100.0;
              double origDiffSec =
                  origDt.difference(lastOrigDt!).inMicroseconds / 1000000.0;
              int fs = imuData.fusionState ?? 0;

              if (!isCompensating) {
                if (fs == 5) {
                  if ((origDiffSec - elapsedSec).abs() > 0.5) {
                    isCompensating = true;
                    recoveryFrames = 0;
                  }
                }
              } else {
                if (fs == 4) {
                  if ((origDiffSec - elapsedSec).abs() < 0.5) {
                    recoveryFrames++;
                    if (recoveryFrames >= 1100) {
                      isCompensating = false;
                      recoveryFrames = 0;
                    }
                  } else {
                    recoveryFrames = 0;
                  }
                } else {
                  recoveryFrames = 0;
                }
              }

              if (isCompensating) {
                int elapsedMicros = (elapsedSec * 1000000).round();
                compDt = lastCompDt!.add(Duration(microseconds: elapsedMicros));
                year = compDt.year;
                month = compDt.month;
                day = compDt.day;
                hour = compDt.hour;
                min = compDt.minute;
                sec = compDt.second;
                msec = compDt.millisecond;
              }
            }

            if (hasRawImuFrame) {
              lastTid = imuData.tid ?? 0;
              lastOrigDt = origDt;
              lastCompDt = compDt;
            }

            // UTC转GPS周和周内秒 (包含18秒闰秒补偿)
            DateTime gpsEpoch = DateTime.utc(1980, 1, 6);
            DateTime gpsDt = compDt.add(const Duration(seconds: 18));
            Duration diff = gpsDt.difference(gpsEpoch);
            int gpsWeek = diff.inDays ~/ 7;
            double gpsSow =
                (diff.inMicroseconds - gpsWeek * 7 * 24 * 3600 * 1000000) /
                1000000.0;

            String timeStr = hasGpsTime
                ? '${outputData.gpsWeek},${outputData.gpsTowNanos! ~/ 1000000000}.${(outputData.gpsTowNanos! % 1000000000).toString().padLeft(9, '0')}'
                : '$gpsWeek,${gpsSow.toStringAsFixed(6)}';

            String row = _decodeOnlyNavigationFrames
                ? timeStr
                : '$timeStr,${f(outputData.wx)},${f(outputData.wy)},${f(outputData.wz)},${f(outputData.ax)},${f(outputData.ay)},${f(outputData.az)}';
            if (_outputTid) {
              row += ',${(outputData.tid ?? 0).toString().padLeft(5, '0')}';
            }
            if (_outputEuler) {
              String eulerF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(5).padLeft(11);
              row +=
                  ',${eulerF(outputData.pitch)},${eulerF(outputData.roll)},${eulerF(outputData.yaw)}';
            }
            if (_outputQuat) {
              String quatF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(6).padLeft(9);
              row +=
                  ',${quatF(outputData.q0)},${quatF(outputData.q1)},${quatF(outputData.q2)},${quatF(outputData.q3)}';
            }
            if (_outputPos) {
              String latF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(10).padLeft(16);
              String lonF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(10).padLeft(15);
              String altF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(3).padLeft(9);
              row +=
                  ',${latF(outputData.lat)},${lonF(outputData.lon)},${altF(outputData.alt)}';
            }
            if (_outputVel) {
              String velF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(3).padLeft(7);
              row +=
                  ',${velF(outputData.ve)},${velF(outputData.vn)},${velF(outputData.vu)}';
            }
            if (_outputStatus) {
              row +=
                  ',${outputData.fusionState ?? 0},${outputData.gnssState ?? 0}';
            }
            if (_outputTemp) {
              String tempF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(2).padLeft(7);
              row += ',${tempF(outputData.tempImu)}';
            }
            if (_outputMag) {
              row +=
                  ',${f(outputData.mx)},${f(outputData.my)},${f(outputData.mz)}';
            }
            outputBuffer.writeln(row);
          }, broadcast: false);

          processedBytes += chunk.length;
          // 批量写出并等待缓冲区清空，避免读取结束后集中等待大量落盘。
          if (processedBytes - lastFlushBytes >= 1024 * 512 ||
              processedBytes == totalBytes) {
            if (outputBuffer.length > 0) {
              sink.write(outputBuffer.toString());
              outputBuffer.clear();
            }
            await sink.flush();
            lastFlushBytes = processedBytes;
            if (!mounted) return;
            setState(() {
              final progress = totalBytes > 0
                  ? processedBytes / totalBytes
                  : 0.0;
              // 只有文件关闭并确认全部写入后才显示 100%。
              item.progress = progress >= 1.0 ? 0.99 : progress;
            });
            await Future.delayed(Duration.zero);
          }
        }

        if (outputBuffer.length > 0) {
          sink.write(outputBuffer.toString());
        }
        await sink.flush();
        await sink.close();
        openedSink = null;

        if (!mounted) return;
        setState(() {
          item.status = '完成';
          item.progress = 1.0;
          item.outputPath = outPath;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          item.status = '错误';
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('解码失败：$e')));
      } finally {
        await openedSink?.close();
      }
    }

    if (!mounted) return;
    setState(() {
      _isDecoding = false;
    });
  }

  void _clearList() {
    setState(() {
      _files.clear();
      _outputDir = null;
    });
  }

  void _deleteSelected() {
    setState(() {
      _files.removeWhere((item) => item.isSelected);
    });
  }

  Widget _option(
    String text,
    bool value,
    ValueChanged<bool> change,
    double width,
  ) => SizedBox(
    width: width,
    child: Row(
      children: [
        Checkbox(
          value: value,
          onChanged: _isDecoding
              ? null
              : (v) => setState(() => change(v ?? false)),
        ),
        Flexible(child: Text(text)),
      ],
    ),
  );

  Widget _mobileContent() => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MobileHero(
          title: '让原始数据清晰可读',
          description: '导入二进制文件，选择需要的字段，批量转换为 CSV。',
          icon: Icons.transform,
          status: MobileStatusChip(
            _isDecoding ? '正在解码' : 'BIN → CSV',
            icon: _isDecoding ? Icons.hourglass_top : Icons.swap_horiz,
            emphasized: _isDecoding,
          ),
        ),
        const MobileSectionTitle('01  导入数据', icon: Icons.file_upload_outlined),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _isDecoding ? null : _pickFiles,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导入文件'),
            ),
            if (Platform.isAndroid)
              OutlinedButton.icon(
                onPressed: _isDecoding ? null : _pickCapture,
                icon: const Icon(Icons.phone_android_outlined),
                label: const Text('导入手机采集'),
              ),
          ],
        ),
        const MobileSectionTitle('02  解码设置', icon: Icons.tune),
        MobilePanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('只解码组合导航结果', style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                  '关闭后导出原始 IMU 数据',
                  style: TextStyle(fontSize: 12),
                ),
                value: _decodeOnlyNavigationFrames,
                onChanged: _isDecoding
                    ? null
                    : (v) => setState(() => _decodeOnlyNavigationFrames = v),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile(
                title: const Text('使用TID补偿时间戳', style: TextStyle(fontSize: 14)),
                subtitle: const Text(
                  '手机采集使用 GPS 时间，无需补偿',
                  style: TextStyle(fontSize: 12),
                ),
                value: _useTidCompensation,
                onChanged: _isDecoding
                    ? null
                    : (v) => setState(() => _useTidCompensation = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const Text('附加输出字段', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            _fieldChip(
              '输出磁场 (µT)',
              Icons.explore_outlined,
              _outputMag,
              (v) => _outputMag = v,
            ),
            _fieldChip(
              '输出欧拉角',
              Icons.screen_rotation_outlined,
              _outputEuler,
              (v) => _outputEuler = v,
            ),
            _fieldChip(
              '输出四元数',
              Icons.view_in_ar_outlined,
              _outputQuat,
              (v) => _outputQuat = v,
            ),
            _fieldChip(
              '输出位置(经纬高)',
              Icons.place_outlined,
              _outputPos,
              (v) => _outputPos = v,
            ),
            _fieldChip(
              '输出速度(东/北/天)',
              Icons.speed_outlined,
              _outputVel,
              (v) => _outputVel = v,
            ),
            _fieldChip(
              '输出状态',
              Icons.verified_outlined,
              _outputStatus,
              (v) => _outputStatus = v,
            ),
            _fieldChip(
              '输出温度',
              Icons.thermostat_outlined,
              _outputTemp,
              (v) => _outputTemp = v,
            ),
            _fieldChip('输出TID', Icons.tag, _outputTid, (v) => _outputTid = v),
          ],
        ),
        const SizedBox(height: 12),
        const MobileNotice('加速度单位 g，角速度 °/s；缺失的轴留空，磁场选项会保留独立磁场帧。'),
        const MobileSectionTitle(
          '03  导出 CSV',
          icon: Icons.table_chart_outlined,
        ),
        MobilePanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('输出目录', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SelectableText(
                _outputDir ??
                    (Platform.isAndroid ? '解码时自动准备本地目录' : '默认(同源文件目录)'),
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _isDecoding || _files.isEmpty
                      ? null
                      : _startDecode,
                  icon: Icon(
                    _isDecoding ? Icons.hourglass_top : Icons.play_arrow,
                  ),
                  label: Text(_isDecoding ? '正在解码…' : '开始解码'),
                ),
              ),
            ],
          ),
        ),
        MobileSectionTitle(
          '文件队列 · ${_files.length}',
          icon: Icons.playlist_add_check,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '清空列表',
                onPressed: _isDecoding ? null : _clearList,
                icon: const Icon(Icons.clear_all),
              ),
              IconButton(
                tooltip: '删除选中',
                onPressed: _isDecoding || !_files.any((f) => f.isSelected)
                    ? null
                    : _deleteSelected,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        if (_files.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: MobileStatusChip(
              '${_files.where((f) => f.status == '完成').length} / ${_files.length} 已完成',
              icon: Icons.task_alt,
            ),
          ),
        if (_files.isEmpty)
          const MobileEmptyState(
            icon: Icons.upload_file_outlined,
            title: '等待导入文件',
            message: '导入 BIN 文件后开始解码，也可以选择手机已保存的采集记录。',
          ),
      ],
    ),
  );

  Widget _fieldChip(
    String label,
    IconData icon,
    bool selected,
    ValueChanged<bool> change,
  ) => FilterChip(
    avatar: ExcludeSemantics(child: Icon(icon, size: 18)),
    label: Text(label),
    selected: selected,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    onSelected: _isDecoding ? null : (v) => setState(() => change(v)),
  );

  @override
  Widget build(BuildContext context) {
    final mobile = Theme.of(context).platform == TargetPlatform.android;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: mobile ? null : 36,
        title: mobile
            ? const FittedBox(child: Text('IMU 批量解码'))
            : const Text(
                'IMU 批量解码',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
        leading: IconButton(
          tooltip: '打开导航',
          icon: const Icon(Icons.menu),
          iconSize: mobile ? 24 : 20,
          padding: mobile ? const EdgeInsets.all(8) : EdgeInsets.zero,
          constraints: mobile ? null : const BoxConstraints(),
          onPressed: widget.onOpenDrawer,
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: mobile
                ? _mobileContent()
                : Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '解码设置',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final width = constraints.maxWidth < 560
                                        ? constraints.maxWidth
                                        : constraints.maxWidth / 2;
                                    return Wrap(
                                      children: [
                                        _option(
                                          '只解码组合导航结果',
                                          _decodeOnlyNavigationFrames,
                                          (v) =>
                                              _decodeOnlyNavigationFrames = v,
                                          width,
                                        ),
                                        _option(
                                          '使用TID补偿时间戳',
                                          _useTidCompensation,
                                          (v) => _useTidCompensation = v,
                                          width,
                                        ),
                                        _option(
                                          '输出磁场 (µT)',
                                          _outputMag,
                                          (v) => _outputMag = v,
                                          width,
                                        ),
                                        _option(
                                          '输出欧拉角',
                                          _outputEuler,
                                          (v) => _outputEuler = v,
                                          width,
                                        ),
                                        _option(
                                          '输出四元数',
                                          _outputQuat,
                                          (v) => _outputQuat = v,
                                          width,
                                        ),
                                        _option(
                                          '输出位置(经纬高)',
                                          _outputPos,
                                          (v) => _outputPos = v,
                                          width,
                                        ),
                                        _option(
                                          '输出速度(东/北/天)',
                                          _outputVel,
                                          (v) => _outputVel = v,
                                          width,
                                        ),
                                        _option(
                                          '输出状态',
                                          _outputStatus,
                                          (v) => _outputStatus = v,
                                          width,
                                        ),
                                        _option(
                                          '输出温度',
                                          _outputTemp,
                                          (v) => _outputTemp = v,
                                          width,
                                        ),
                                        _option(
                                          '输出TID',
                                          _outputTid,
                                          (v) => _outputTid = v,
                                          width,
                                        ),
                                      ],
                                    );
                                  },
                                ),
                                const Text(
                                  '手机采集使用 GPS 时间，无需 TID 补偿。加速度单位 g，角速度 °/s；缺失的轴留空，磁场选项会保留独立磁场帧。',
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ElevatedButton.icon(
                              onPressed: _isDecoding ? null : _pickFiles,
                              icon: const Icon(Icons.file_upload),
                              label: const Text('导入文件'),
                            ),
                            if (Platform.isAndroid)
                              ElevatedButton.icon(
                                onPressed: _isDecoding ? null : _pickCapture,
                                icon: const Icon(Icons.phone_android),
                                label: const Text('导入手机采集'),
                              ),
                            if (!Platform.isAndroid)
                              ElevatedButton.icon(
                                onPressed: _isDecoding ? null : _pickOutputDir,
                                icon: const Icon(Icons.folder),
                                label: const Text('选择输出目录'),
                              ),
                            ElevatedButton.icon(
                              onPressed: _isDecoding || _files.isEmpty
                                  ? null
                                  : _startDecode,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('开始解码'),
                            ),
                            IconButton(
                              tooltip: '清空列表',
                              onPressed: _isDecoding ? null : _clearList,
                              icon: const Icon(Icons.clear_all),
                            ),
                            IconButton(
                              tooltip: '删除选中',
                              onPressed:
                                  _isDecoding ||
                                      !_files.any((f) => f.isSelected)
                                  ? null
                                  : _deleteSelected,
                              icon: const Icon(Icons.delete),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SelectableText('输出目录: ${_outputDir ?? "默认(同源文件目录)"}'),
                        if (_files.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text('导入 BIN 文件后开始解码'),
                          ),
                      ],
                    ),
                  ),
          ),
          SliverList.builder(
            itemCount: _files.length,
            itemBuilder: (context, index) {
              final item = _files[index];
              final mobile =
                  Theme.of(context).platform == TargetPlatform.android;
              return Card(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: item.isSelected,
                            onChanged: _isDecoding
                                ? null
                                : (v) => setState(
                                    () => item.isSelected = v ?? false,
                                  ),
                          ),
                          Expanded(
                            child: mobile
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const ExcludeSemantics(
                                            child: Icon(
                                              Icons.description_outlined,
                                              size: 20,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              item.path
                                                  .split(RegExp(r'[/\\]'))
                                                  .last,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      SelectableText(
                                        item.path,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          height: 1.6,
                                        ),
                                      ),
                                    ],
                                  )
                                : SelectableText(item.path),
                          ),
                        ],
                      ),
                      if (item.status == '解码中...')
                        LinearProgressIndicator(value: item.progress),
                      if (mobile)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: MobileStatusChip(
                            item.status == '解码中...'
                                ? '解码中 · ${(item.progress * 100).toStringAsFixed(1)}%'
                                : item.status,
                            icon: item.status == '完成'
                                ? Icons.check_circle_outline
                                : item.status == '错误'
                                ? Icons.error_outline
                                : Icons.hourglass_top,
                            emphasized: item.status == '完成',
                          ),
                        )
                      else
                        Text(
                          item.status == '解码中...'
                              ? '${(item.progress * 100).toStringAsFixed(1)}%'
                              : item.status,
                          style: TextStyle(
                            color: item.status == '完成'
                                ? Colors.green
                                : item.status == '错误'
                                ? Colors.red
                                : null,
                          ),
                        ),
                      if (item.outputPath != null)
                        SelectableText(item.outputPath!),
                      if (Platform.isAndroid && item.outputPath != null)
                        TextButton.icon(
                          onPressed: () async {
                            try {
                              await PhoneCaptureService.channel
                                  .invokeMethod<void>('share', {
                                    'paths': [item.outputPath],
                                  });
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('分享失败：$e')),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.share),
                          label: const Text('分享 CSV'),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
