import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'imu_data_parser.dart';

PositionHistoryPoint? parsePositionLine(String line, {bool ggaOnly = false}) {
  if (RegExp(r'^\$[A-Z]{2}GGA,').hasMatch(line)) {
    try {
      final parts = line.split(',');
      if (parts.length < 15) return null;

      final int status = int.tryParse(parts[6]) ?? 0;
      if (status == 0) return null;

      final String rawTime = parts[1];
      String timeStr = rawTime;
      if (rawTime.length >= 6) {
        timeStr =
            "${rawTime.substring(0, 2)}:${rawTime.substring(2, 4)}:${rawTime.substring(4)}";
      }

      final latStr = parts[2];
      final latDir = parts[3];
      final lonStr = parts[4];
      final lonDir = parts[5];

      if (latStr.isEmpty || lonStr.isEmpty) return null;

      double convertNmeaToDegree(double nmeaArr) {
        double deg = (nmeaArr / 100).floorToDouble();
        double min = nmeaArr - deg * 100;
        return deg + min / 60.0;
      }

      final rawLat = double.tryParse(latStr);
      final rawLon = double.tryParse(lonStr);
      if (rawLat == null ||
          rawLon == null ||
          !rawLat.isFinite ||
          !rawLon.isFinite ||
          rawLat < 0 ||
          rawLon < 0 ||
          rawLat > 9000 ||
          rawLon > 18000 ||
          rawLat % 100 >= 60 ||
          rawLon % 100 >= 60 ||
          !['N', 'S'].contains(latDir) ||
          !['E', 'W'].contains(lonDir)) {
        return null;
      }
      double lat = convertNmeaToDegree(rawLat);
      if (latDir == 'S') lat = -lat;

      double lon = convertNmeaToDegree(rawLon);
      if (lonDir == 'W') lon = -lon;

      final LatLng gcj02Pos = CoordinateConverter.wgs84ToGcj02(lat, lon);

      final newInfo = PositionInfo(
        utcTime: timeStr,
        status: status,
        speed: 0.0,
        posAcc: 0.0,
        speedAcc: 0.0,
        dop1: double.tryParse(parts[8]) ?? 0.0,
        dop2: 0,
        dop3: 0,
        satellites: int.tryParse(parts[7]) ?? 0,
        altitude: double.tryParse(parts[9]) ?? 0.0,
        differentialAge: double.tryParse(parts[13]),
        type: PointType.gga,
      );

      return PositionHistoryPoint(
        location: gcj02Pos,
        status: status,
        isImu: false,
        type: PointType.gga,
        posInfo: newInfo,
      );
    } catch (e) {
      debugPrint('Error parsing GGA: $e');
      return null;
    }
  }

  if (ggaOnly || !line.startsWith('\$PPPSOL')) return null;

  try {
    final parts = line.split(',');
    if (parts.length < 23) return null; // Ensure we have enough fields

    // Parse Status
    final int status = int.tryParse(parts[2]) ?? 0;

    // Parse Coordinates
    final double lon = double.tryParse(parts[4]) ?? 0.0;
    final double lat = double.tryParse(parts[6]) ?? 0.0;

    if (lon == 0 && lat == 0) return null;

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
      satellites: int.tryParse(parts[3]) ?? 0,
      altitude: double.tryParse(parts[8]) ?? 0.0,
      type: PointType.pppsol,
    );

    return PositionHistoryPoint(
      location: gcj02Pos,
      status: status,
      isImu: false,
      type: PointType.pppsol,
      posInfo: newInfo,
    );
  } catch (e) {
    debugPrint('Error parsing PPPSOL: $e');
    return null;
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
  final int satellites;
  final double altitude;
  final double? differentialAge;
  final PointType type;

  PositionInfo({
    required this.utcTime,
    required this.status,
    required this.speed,
    required this.posAcc,
    required this.speedAcc,
    required this.dop1,
    required this.dop2,
    required this.dop3,
    this.satellites = 0,
    this.altitude = 0.0,
    this.differentialAge,
    this.type = PointType.pppsol,
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

enum PointType { imu, pppsol, gga }

class PositionHistoryPoint {
  final LatLng location;
  final int status;
  final bool isImu;
  final PointType type;
  final ImuData? imuData;
  final PositionInfo? posInfo;

  PositionHistoryPoint({
    required this.location,
    required this.status,
    this.isImu = false,
    this.type = PointType.imu,
    this.imuData,
    this.posInfo,
  });
}
