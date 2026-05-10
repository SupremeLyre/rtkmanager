import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'serial_service.dart';
import 'imu_data_parser.dart';

class MobilePositioningPage extends StatefulWidget {
  final VoidCallback onOpenDrawer;

  const MobilePositioningPage({super.key, required this.onOpenDrawer});

  @override
  State<MobilePositioningPage> createState() => _MobilePositioningPageState();
}

class _MobilePositioningPageState extends State<MobilePositioningPage> {
  final MapController _mapController = MapController();
  final List<PositionHistoryPoint> _points = [];
  StreamSubscription<String>? _subscription;
  StreamSubscription<ImuData>? _imuSubscription;
  bool _autoCenter = true;
  bool _showTimeline = true;
  bool _isImportMode = false;
  bool _isImporting = false;
  double _importProgress = 0.0;
  PositionInfo? _currentInfo;
  ImuData? _currentImuInfo;
  int? _selectedIndex;

  // Gaode Map Tile URL (Standard/Vector implementation)
  final String _amapUrl =
      'http://webrd{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}';

  @override
  void initState() {
    super.initState();
    // Subscribe to the serial service line stream
    _subscription = SerialService().lineStream.listen(_handleLine);
    _imuSubscription = ImuDataParser.imuDataStream.listen(_handleImuData);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _imuSubscription?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  int _getEffectiveImuStatus(ImuData data) {
    int status = data.gnssState ?? 0;
    if ((status < 1 || status > 5) && data.fusionState == 5) {
      return 6;
    }
    return status;
  }

  void _handleImuData(ImuData data) {
    if (data.utcYear != null &&
        data.utcYear! > 2000 &&
        data.utcMsec != null &&
        data.utcMsec! % 1000 == 0) {
      if (data.lat != null &&
          data.lon != null &&
          data.lat! != 0 &&
          data.lon! != 0) {
        final gcj02Pos = CoordinateConverter.wgs84ToGcj02(data.lat!, data.lon!);

        final int status = _getEffectiveImuStatus(data);
        final point = PositionHistoryPoint(
          location: gcj02Pos,
          status: status,
          isImu: true,
          imuData: data,
        );

        setState(() {
          _currentImuInfo = data;
          _currentInfo = null;
          _points.add(point);
          if (_selectedIndex == null) {
            // Only auto scroll if we are tracking latest
            if (_points.length > 5000) {
              _points.removeAt(0);
            }
          }
        });

        if (_autoCenter && _selectedIndex == null) {
          _mapController.move(gcj02Pos, _mapController.camera.zoom);
        }
      }
    }
  }

  void _handleLine(String line) {
    // $PPPSOL,20260107121342.00,4,08,114.35696878,0.016,30.52845181,...
    if (!line.startsWith('\$PPPSOL')) return;

    try {
      final parts = line.split(',');
      if (parts.length < 23) return; // Ensure we have enough fields

      // Parse Status
      final int status = int.tryParse(parts[2]) ?? 0;

      // Parse Coordinates
      final double lon = double.tryParse(parts[4]) ?? 0.0;
      final double lat = double.tryParse(parts[6]) ?? 0.0;

      if (lon == 0 && lat == 0) return;

      // Convert WGS84 to GCJ-02
      final LatLng gcj02Pos = CoordinateConverter.wgs84ToGcj02(lat, lon);

      // Parse Additional Info
      final String rawTime = parts[1];
      String timeStr = rawTime;
      if (rawTime.length >= 14) {
        // yyyymmddhhmmss.ss -> hh:mm:ss.ss
        timeStr =
            "${rawTime.substring(8, 10)}:${rawTime.substring(10, 12)}:${rawTime.substring(12)}";
      }

      // Accuracy
      final double eastAcc = double.tryParse(parts[5]) ?? 0.0;
      final double northAcc = double.tryParse(parts[7]) ?? 0.0;
      final double upAcc = double.tryParse(parts[9]) ?? 0.0;
      final double posAcc3D = sqrt(
        eastAcc * eastAcc + northAcc * northAcc + upAcc * upAcc,
      );

      // Velocity
      final double ve = double.tryParse(parts[11]) ?? 0.0;
      final double vn = double.tryParse(parts[13]) ?? 0.0;
      final double vu = double.tryParse(parts[15]) ?? 0.0;
      final double speed3D = sqrt(ve * ve + vn * vn + vu * vu);

      // Velocity Accuracy
      final double veAcc = double.tryParse(parts[12]) ?? 0.0;
      final double vnAcc = double.tryParse(parts[14]) ?? 0.0;
      final double vuAcc = double.tryParse(parts[16]) ?? 0.0;
      final double speedAcc3D = sqrt(
        veAcc * veAcc + vnAcc * vnAcc + vuAcc * vuAcc,
      );

      // DOPs
      final double dop1 = double.tryParse(parts[20]) ?? 0.0;
      final double dop2 = double.tryParse(parts[21]) ?? 0.0;
      final double dop3 = double.tryParse(parts[22]) ?? 0.0;

      final newInfo = PositionInfo(
        utcTime: timeStr,
        status: status,
        speed: speed3D,
        posAcc: posAcc3D,
        speedAcc: speedAcc3D,
        dop1: dop1,
        dop2: dop2,
        dop3: dop3,
      );

      final point = PositionHistoryPoint(
        location: gcj02Pos,
        status: status,
        isImu: false,
        posInfo: newInfo,
      );

      setState(() {
        if (_selectedIndex == null) {
          _currentInfo = newInfo;
          _currentImuInfo = null;
        }
        _points.add(point);
        // Keep a reasonable buffer if needed, e.g., last 10000 points
        if (_selectedIndex == null && _points.length > 5000) {
          _points.removeAt(0);
        }
      });

      if (_autoCenter && _selectedIndex == null) {
        _mapController.move(gcj02Pos, _mapController.camera.zoom);
      }
    } catch (e) {
      debugPrint('Error parsing PPPSOL: $e');
    }
  }

  Color _getColorForStatus(int status, bool isImu) {
    if (isImu) {
      switch (status) {
        case 1:
          return Colors.red; // SPP
        case 2:
          return Colors.pink; // DGPS
        case 4:
          return Colors.green; // RTK FIX
        case 5:
          return Colors.brown; // RTK FLOAT
        case 6:
          return Colors.blue; // DR (纯惯导推算)
        default:
          return Colors.grey;
      }
    } else {
      switch (status) {
        case 3: // SPP
          return Colors.pink;
        case 4: // PPP
          return Colors.blue;
        case 5: // Prediction
          return Colors.red;
        default:
          return Colors.grey;
      }
    }
  }

  String _getStatusText(int status, bool isImu) {
    if (isImu) {
      switch (status) {
        case 1:
          return "SPP (1)";
        case 2:
          return "DGPS (2)";
        case 4:
          return "RTK FIX (4)";
        case 5:
          return "RTK FLOAT (5)";
        case 6:
          return "DR (6)";
        default:
          return "UNKNOWN ($status)";
      }
    } else {
      switch (status) {
        case 3:
          return "SPP (3)";
        case 4:
          return "PPP (4)";
        case 5:
          return "PRED (5)";
        default:
          return "UNKNOWN ($status)";
      }
    }
  }

  Future<void> _importFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles();

      if (result != null && result.files.single.path != null) {
        File file = File(result.files.single.path!);
        final int totalBytes = await file.length();
        int processedBytes = 0;

        setState(() {
          _points.clear();
          _autoCenter = false; // Disable auto center during bulk import
          _currentInfo = null;
          _selectedIndex = null;
          _isImportMode = true;
          _isImporting = true;
          _importProgress = 0.0;
        });

        final parser = ImuDataParser();
        List<PositionHistoryPoint> newPoints = [];
        ImuData? lastData;
        int? lastSec;
        bool firstPointFound = false;

        int lastYieldTime = DateTime.now().millisecondsSinceEpoch;
        int lastProgressUpdate = DateTime.now().millisecondsSinceEpoch;

        // Parse chunk by chunk to avoid out of memory and UI freeze
        await for (final chunk in file.openRead()) {
          processedBytes += chunk.length;
          parser.parseData(chunk, (data) {
            if (data.utcYear != null &&
                data.utcYear! > 2000 &&
                data.utcSec != null &&
                data.utcSec != lastSec) {
              if (data.lat != null &&
                  data.lon != null &&
                  data.lat! != 0 &&
                  data.lon! != 0) {
                lastSec = data.utcSec;

                final gcj02Pos = CoordinateConverter.wgs84ToGcj02(
                  data.lat!,
                  data.lon!,
                );

                final int status = _getEffectiveImuStatus(data);
                final point = PositionHistoryPoint(
                  location: gcj02Pos,
                  status: status,
                  isImu: true,
                  imuData: data,
                );

                newPoints.add(point);
                lastData = data;

                if (!firstPointFound) {
                  firstPointFound = true;
                  // Immediately add first point and center map
                  _points.add(point);
                  newPoints.clear();
                  if (mounted) {
                    setState(() {
                      _selectedIndex = 0;
                      _mapController.move(
                        point.location,
                        _mapController.camera.zoom,
                      );
                      _currentImuInfo = data;
                    });
                  }
                }
              }
            }
          }, broadcast: false);

          // Update progress every 100ms to avoid too many setState calls
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastProgressUpdate > 100) {
            setState(() {
              _importProgress = totalBytes > 0
                  ? processedBytes / totalBytes
                  : 0.0;
              if (newPoints.isNotEmpty) {
                _points.addAll(newPoints);
                newPoints.clear();
              }
            });
            lastProgressUpdate = now;
          }

          // Yield control to UI thread every 20ms to prevent freezing
          if (now - lastYieldTime > 20) {
            await Future.delayed(Duration.zero);
            lastYieldTime = now;
          }
        }

        setState(() {
          if (newPoints.isNotEmpty) {
            _points.addAll(newPoints);
            newPoints.clear();
          }
          if (_points.length > 50000) {
            // Keep more points for imported files
            _points.removeRange(0, _points.length - 50000);
          }
          _isImporting = false;
          _importProgress = 1.0;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件解析完成，共载入 ${_points.length} 个轨迹点')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error importing file: $e');
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgress = 0.0;
        });
      }
    }
  }

  void _updateToSelectedEpoch(int index) {
    setState(() {
      _selectedIndex = index;
      _autoCenter = false; // Disable auto center when manually reviewing
      final point = _points[index];
      _mapController.move(point.location, _mapController.camera.zoom);
      if (point.isImu) {
        _currentImuInfo = point.imuData;
        _currentInfo = null;
      } else {
        _currentInfo = point.posInfo;
        _currentImuInfo = null;
      }
    });
  }

  void _clearPoints() {
    setState(() {
      _points.clear();
      _currentInfo = null;
      _currentImuInfo = null;
      _selectedIndex = null;
      _isImportMode = false;
      _isImporting = false;
      _importProgress = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 36,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: widget.onOpenDrawer,
        ),
        title: const Text(
          '定位结果 (高德)',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: '从文件导入IMU定位数据',
            onPressed: _importFile,
          ),
          IconButton(
            icon: Icon(
              _autoCenter ? Icons.center_focus_strong : Icons.center_focus_weak,
            ),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: '自动跟随',
            onPressed: () {
              setState(() {
                _autoCenter = !_autoCenter;
              });
            },
          ),
          if (_isImportMode)
            IconButton(
              icon: Icon(_showTimeline ? Icons.timeline : Icons.linear_scale),
              iconSize: 20,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: _showTimeline ? '隐藏时间轴' : '显示时间轴',
              onPressed: () {
                setState(() {
                  _showTimeline = !_showTimeline;
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.delete),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: '清除轨迹',
            onPressed: _clearPoints,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              // Default center (Wuhan as per example coords)
              initialCenter: const LatLng(30.52845181, 114.35696878),
              initialZoom: 17,
            ),
            children: [
              TileLayer(
                urlTemplate: _amapUrl,
                userAgentPackageName: 'com.example.rtkmanager',
                subdomains: const ['01', '02', '03', '04'], // usually wprd01-04
              ),
              // Using CircleMarkers for points as they are more performant for many points than Icons
              CircleLayer(
                circles: _points
                    .map(
                      (p) => CircleMarker(
                        point: p.location,
                        color: _getColorForStatus(
                          p.status,
                          p.isImu,
                        ).withValues(alpha: 0.8),
                        borderStrokeWidth: 0.5,
                        borderColor: Colors.white,
                        radius: 2, // visible size
                        useRadiusInMeter: false,
                      ),
                    )
                    .toList(),
              ),
              if (_points.isNotEmpty)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: _points[_selectedIndex ?? (_points.length - 1)]
                          .location,
                      color: Colors.yellow.withValues(alpha: 0.8),
                      borderStrokeWidth: 1.5,
                      borderColor: Colors.black,
                      radius: 6,
                    ),
                  ],
                ),
            ],
          ),
          if (_currentInfo != null)
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "UTC: ${_currentInfo!.utcTime}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Text(
                          "Stat: ",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        Text(
                          _getStatusText(_currentInfo!.status, false),
                          style: TextStyle(
                            color: _getColorForStatus(
                              _currentInfo!.status,
                              false,
                            ),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Speed: ${_currentInfo!.speed.toStringAsFixed(3)} m/s",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Pos Acc: ${_currentInfo!.posAcc.toStringAsFixed(3)} m",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Spd Acc: ${_currentInfo!.speedAcc.toStringAsFixed(3)} m/s",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "DOP: ${_currentInfo!.dop1.toStringAsFixed(2)} / ${_currentInfo!.dop2.toStringAsFixed(2)} / ${_currentInfo!.dop3.toStringAsFixed(2)}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (_currentImuInfo != null)
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "UTC: ${_currentImuInfo!.utcHour?.toString().padLeft(2, '0')}:${_currentImuInfo!.utcMin?.toString().padLeft(2, '0')}:${_currentImuInfo!.utcSec?.toString().padLeft(2, '0')}.${_currentImuInfo!.utcMsec?.toString().padLeft(3, '0')}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Text(
                          "GNSS/Fusion: ",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        Text(
                          "${_currentImuInfo!.gnssState} / ${_currentImuInfo!.fusionState} (${_getStatusText(_getEffectiveImuStatus(_currentImuInfo!), true).replaceAll('\n', ' ')})",
                          style: TextStyle(
                            color: _getColorForStatus(
                              _getEffectiveImuStatus(_currentImuInfo!),
                              true,
                            ),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Speed: ${sqrt((_currentImuInfo!.ve ?? 0) * (_currentImuInfo!.ve ?? 0) + (_currentImuInfo!.vn ?? 0) * (_currentImuInfo!.vn ?? 0) + (_currentImuInfo!.vu ?? 0) * (_currentImuInfo!.vu ?? 0)).toStringAsFixed(3)} m/s",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Euler: ${_currentImuInfo!.pitch?.toStringAsFixed(2)}, ${_currentImuInfo!.roll?.toStringAsFixed(2)}, ${_currentImuInfo!.yaw?.toStringAsFixed(2)}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Acc: ${_currentImuInfo!.ax?.toStringAsFixed(3)}, ${_currentImuInfo!.ay?.toStringAsFixed(3)}, ${_currentImuInfo!.az?.toStringAsFixed(3)}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Gyro: ${_currentImuInfo!.wx?.toStringAsFixed(3)}, ${_currentImuInfo!.wy?.toStringAsFixed(3)}, ${_currentImuInfo!.wz?.toStringAsFixed(3)}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (_points.isNotEmpty && _showTimeline && _isImportMode)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 2.0,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6.0,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14.0,
                          ),
                        ),
                        child: Slider(
                          value: (_selectedIndex ?? (_points.length - 1))
                              .toDouble(),
                          min: 0,
                          max: (_points.length <= 1
                              ? 1.0
                              : (_points.length - 1).toDouble()),
                          onChanged: _points.length <= 1
                              ? null
                              : (value) {
                                  _updateToSelectedEpoch(value.toInt());
                                },
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.chevron_left,
                        color: Colors.white,
                        size: 20,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: () {
                        if (_points.isEmpty) return;
                        int currentIndex =
                            _selectedIndex ?? (_points.length - 1);
                        if (currentIndex > 0) {
                          _updateToSelectedEpoch(currentIndex - 1);
                        }
                      },
                      tooltip: '上一历元',
                    ),
                    Text(
                      '${(_selectedIndex ?? (_points.length - 1)) + 1} / ${_points.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.chevron_right,
                        color: Colors.white,
                        size: 20,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: () {
                        if (_points.isEmpty) return;
                        int currentIndex =
                            _selectedIndex ?? (_points.length - 1);
                        if (currentIndex < _points.length - 1) {
                          _updateToSelectedEpoch(currentIndex + 1);
                        }
                      },
                      tooltip: '下一历元',
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next,
                        color: Colors.white,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _selectedIndex = null;
                          if (_points.isNotEmpty) {
                            final point = _points.last;
                            if (point.isImu) {
                              _currentImuInfo = point.imuData;
                              _currentInfo = null;
                            } else {
                              _currentInfo = point.posInfo;
                              _currentImuInfo = null;
                            }
                            if (_autoCenter) {
                              _mapController.move(
                                point.location,
                                _mapController.camera.zoom,
                              );
                            }
                          }
                        });
                      },
                      tooltip: '回到最新',
                    ),
                  ],
                ),
              ),
            ),
          // Import progress bar overlay at the bottom
          if (_isImporting)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(8),
                    topRight: Radius.circular(8),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '正在导入IMU数据...',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _importProgress,
                        minHeight: 6,
                        backgroundColor: Colors.grey[700],
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.greenAccent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${(_importProgress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class PositionInfo {
  final String utcTime;
  final int status;
  final double speed;
  final double posAcc;
  final double speedAcc;
  final double dop1;
  final double dop2;
  final double dop3;

  PositionInfo({
    required this.utcTime,
    required this.status,
    required this.speed,
    required this.posAcc,
    required this.speedAcc,
    required this.dop1,
    required this.dop2,
    required this.dop3,
  });
}

class CoordinateConverter {
  static const double pi = 3.1415926535897932384626;
  static const double a = 6378245.0;
  static const double ee = 0.00669342162296594323;

  static LatLng wgs84ToGcj02(double lat, double lon) {
    if (outOfChina(lat, lon)) {
      return LatLng(lat, lon);
    }
    double dLat = transformLat(lon - 105.0, lat - 35.0);
    double dLon = transformLon(lon - 105.0, lat - 35.0);
    double radLat = lat / 180.0 * pi;
    double magic = sin(radLat);
    magic = 1 - ee * magic * magic;
    double sqrtMagic = sqrt(magic);
    dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi);
    dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * pi);
    return LatLng(lat + dLat, lon + dLon);
  }

  static bool outOfChina(double lat, double lon) {
    if (lon < 72.004 || lon > 137.8347) return true;
    if (lat < 0.8293 || lat > 55.8271) return true;
    return false;
  }

  static double transformLat(double x, double y) {
    double ret =
        -100.0 +
        2.0 * x +
        3.0 * y +
        0.2 * y * y +
        0.1 * x * y +
        0.2 * sqrt(x.abs());
    ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0;
    ret += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0;
    ret += (160.0 * sin(y / 12.0 * pi) + 320 * sin(y * pi / 30.0)) * 2.0 / 3.0;
    return ret;
  }

  static double transformLon(double x, double y) {
    double ret =
        300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(x.abs());
    ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0;
    ret += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0;
    ret +=
        (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0;
    return ret;
  }
}

class PositionHistoryPoint {
  final LatLng location;
  final int status;
  final bool isImu;
  final ImuData? imuData;
  final PositionInfo? posInfo;

  PositionHistoryPoint({
    required this.location,
    required this.status,
    this.isImu = false,
    this.imuData,
    this.posInfo,
  });
}
