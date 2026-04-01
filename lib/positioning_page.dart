import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
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
  PositionInfo? _currentInfo;
  ImuData? _currentImuInfo;

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
    if (data.utcMsec != null && data.utcMsec! % 1000 == 0) {
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
        );

        setState(() {
          _currentImuInfo = data;
          _currentInfo = null;
          _points.add(point);
          if (_points.length > 5000) {
            _points.removeAt(0);
          }
        });

        if (_autoCenter) {
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
      );

      setState(() {
        _currentInfo = newInfo;
        _currentImuInfo = null;
        _points.add(point);
        // Keep a reasonable buffer if needed, e.g., last 10000 points
        if (_points.length > 5000) {
          _points.removeAt(0);
        }
      });

      if (_autoCenter) {
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
          return Colors.orange; // RTK FIX
        case 5:
          return Colors.green; // RTK FLOAT
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

  void _clearPoints() {
    setState(() {
      _points.clear();
      _currentInfo = null;
      _currentImuInfo = null;
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

  PositionHistoryPoint({
    required this.location,
    required this.status,
    this.isImu = false,
  });
}
