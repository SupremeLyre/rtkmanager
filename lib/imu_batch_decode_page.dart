import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'imu_data_parser.dart';

class FileItem {
  final String path;
  String status;
  double progress;
  bool isSelected;
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
  bool _useTidCompensation = true;
  bool _outputEuler = false;
  bool _outputQuat = false;
  bool _outputPos = false;
  bool _outputVel = false;
  bool _outputStatus = false;
  bool _outputTemp = false;
  bool _outputTid = false;

  Future<void> _pickFiles() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (result != null) {
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
    if (selectedDirectory != null) {
      setState(() {
        _outputDir = selectedDirectory;
      });
    }
  }

  Future<void> _startDecode() async {
    if (_isDecoding || _files.isEmpty) return;
    setState(() {
      _isDecoding = true;
    });

    for (var item in _files) {
      if (item.status == '完成') continue;

      setState(() {
        item.status = '解码中...';
        item.progress = 0.0;
      });

      try {
        final parser = ImuDataParser();
        final file = File(item.path);
        final totalBytes = await file.length();
        int processedBytes = 0;
        int lastUpdateBytes = 0;

        final lastSep = item.path.lastIndexOf(Platform.pathSeparator);
        final fileName = lastSep != -1
            ? item.path.substring(lastSep + 1)
            : item.path;

        final outDir = _outputDir ?? file.parent.path;
        final outPath = '$outDir${Platform.pathSeparator}$fileName.csv';
        final outFile = File(outPath);

        final sink = outFile.openWrite();

        String header = "UTCTimestamp,gx,gy,gz,ax,ay,az";
        if (_outputTid) header += ",tid";
        if (_outputEuler) header += ",pitch,roll,yaw";
        if (_outputQuat) header += ",q0,q1,q2,q3";
        if (_outputPos) header += ",lat,lon,alt";
        if (_outputVel) header += ",ve,vn,vu";
        if (_outputStatus) header += ",fusionState,gnssState";
        if (_outputTemp) header += ",tempImu";
        sink.writeln(header);

        String f(double? val) {
          return (val ?? 0.0).toStringAsFixed(6).padLeft(10);
        }

        bool hasValidTime = false;
        bool isCompensating = false;
        int recoveryFrames = 0;
        int lastTid = -1;
        DateTime? lastOrigDt;
        DateTime? lastCompDt;

        await for (final chunk in file.openRead()) {
          parser.parseData(chunk, (imuData) {
            int year = imuData.utcYear ?? 0;
            int month = imuData.utcMonth ?? 0;
            int day = imuData.utcDay ?? 0;
            int hour = imuData.utcHour ?? 0;
            int min = imuData.utcMin ?? 0;
            int sec = imuData.utcSec ?? 0;
            int msec = imuData.utcMsec ?? 0;

            if (year < 2026 || month == 0 || day == 0) return;

            if (!hasValidTime) {
              if (hour == 0 && min == 0) return;
              hasValidTime = true;
            }

            DateTime origDt = DateTime.utc(
              year,
              month,
              day,
              hour,
              min,
              sec,
              msec,
            );
            DateTime compDt = origDt;

            if (_useTidCompensation &&
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

            lastTid = imuData.tid ?? 0;
            lastOrigDt = origDt;
            lastCompDt = compDt;

            String utcStr =
                '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')} ${hour.toString().padLeft(2, '0')}:${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.${msec.toString().padLeft(3, '0')}';

            String row =
                '$utcStr,${f(imuData.wx)},${f(imuData.wy)},${f(imuData.wz)},${f(imuData.ax)},${f(imuData.ay)},${f(imuData.az)}';
            if (_outputTid) {
              row += ',${(imuData.tid ?? 0).toString().padLeft(5, '0')}';
            }
            if (_outputEuler) {
              String eulerF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(5).padLeft(11);
              row +=
                  ',${eulerF(imuData.pitch)},${eulerF(imuData.roll)},${eulerF(imuData.yaw)}';
            }
            if (_outputQuat) {
              String quatF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(6).padLeft(9);
              row +=
                  ',${quatF(imuData.q0)},${quatF(imuData.q1)},${quatF(imuData.q2)},${quatF(imuData.q3)}';
            }
            if (_outputPos) {
              String latF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(10).padLeft(16);
              String lonF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(10).padLeft(15);
              String altF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(3).padLeft(9);
              row +=
                  ',${latF(imuData.lat)},${lonF(imuData.lon)},${altF(imuData.alt)}';
            }
            if (_outputVel) {
              String velF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(3).padLeft(7);
              row +=
                  ',${velF(imuData.ve)},${velF(imuData.vn)},${velF(imuData.vu)}';
            }
            if (_outputStatus) {
              row += ',${imuData.fusionState ?? 0},${imuData.gnssState ?? 0}';
            }
            if (_outputTemp) {
              String tempF(double? v) =>
                  (v ?? 0.0).toStringAsFixed(2).padLeft(7);
              row += ',${tempF(imuData.tempImu)}';
            }
            sink.writeln(row);
          }, broadcast: false);

          processedBytes += chunk.length;
          // 防止频繁刷新导致界面卡顿，每读取一定量或完成时更新一次
          if (processedBytes - lastUpdateBytes > 1024 * 512 ||
              processedBytes == totalBytes) {
            lastUpdateBytes = processedBytes;
            setState(() {
              item.progress = totalBytes > 0
                  ? (processedBytes / totalBytes)
                  : 0.0;
            });
            await Future.delayed(Duration.zero);
          }
        }

        await sink.flush();
        await sink.close();

        setState(() {
          item.status = '完成';
          item.progress = 1.0;
        });
      } catch (e) {
        setState(() {
          item.status = '错误';
        });
      }
    }

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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 50,
          color: Colors.blue,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.menu, color: Colors.white),
                onPressed: widget.onOpenDrawer,
              ),
              const Text(
                'IMU 批量解码',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ],
          ),
        ),
        // 解码设置区域
        Card(
          margin: const EdgeInsets.all(8.0),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '解码设置',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _useTidCompensation,
                          onChanged: _isDecoding
                              ? null
                              : (v) => setState(
                                  () => _useTidCompensation = v ?? true,
                                ),
                        ),
                        const Text('使用TID补偿时间戳'),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _outputEuler,
                          onChanged: _isDecoding
                              ? null
                              : (v) =>
                                    setState(() => _outputEuler = v ?? false),
                        ),
                        const Text('输出欧拉角'),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _outputQuat,
                          onChanged: _isDecoding
                              ? null
                              : (v) => setState(() => _outputQuat = v ?? false),
                        ),
                        const Text('输出四元数'),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _outputPos,
                          onChanged: _isDecoding
                              ? null
                              : (v) => setState(() => _outputPos = v ?? false),
                        ),
                        const Text('输出位置(经纬高)'),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _outputVel,
                          onChanged: _isDecoding
                              ? null
                              : (v) => setState(() => _outputVel = v ?? false),
                        ),
                        const Text('输出速度(东/北/天)'),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _outputStatus,
                          onChanged: _isDecoding
                              ? null
                              : (v) =>
                                    setState(() => _outputStatus = v ?? false),
                        ),
                        const Text('输出状态'),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _outputTemp,
                          onChanged: _isDecoding
                              ? null
                              : (v) => setState(() => _outputTemp = v ?? false),
                        ),
                        const Text('输出温度'),
                      ],
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _outputTid,
                          onChanged: _isDecoding
                              ? null
                              : (v) => setState(() => _outputTid = v ?? false),
                        ),
                        const Text('输出TID'),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // Toolbar
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: _isDecoding ? null : _pickFiles,
                icon: const Icon(Icons.file_upload),
                label: const Text('导入文件'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _isDecoding ? null : _pickOutputDir,
                icon: const Icon(Icons.folder),
                label: const Text('选择输出目录'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _isDecoding || _files.isEmpty ? null : _startDecode,
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始解码'),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.clear_all),
                tooltip: '清空列表',
                onPressed: _isDecoding ? null : _clearList,
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete),
                tooltip: '删除选中',
                onPressed: _isDecoding || !_files.any((f) => f.isSelected)
                    ? null
                    : _deleteSelected,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '输出目录: ${_outputDir ?? "默认(同源文件目录)"}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _files.length,
            itemBuilder: (context, index) {
              final item = _files[index];
              return ListTile(
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: item.isSelected,
                      onChanged: _isDecoding
                          ? null
                          : (val) {
                              setState(() {
                                item.isSelected = val ?? false;
                              });
                            },
                    ),
                    const Icon(Icons.insert_drive_file),
                  ],
                ),
                title: Text(item.path),
                trailing: SizedBox(
                  width: 120,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (item.status == '解码中...')
                        Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              value: item.progress,
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      Text(
                        item.status == '解码中...'
                            ? '${(item.progress * 100).toStringAsFixed(1)}%'
                            : item.status,
                        style: TextStyle(
                          color: item.status == '完成'
                              ? Colors.green
                              : (item.status == '错误'
                                    ? Colors.red
                                    : Colors.grey),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
