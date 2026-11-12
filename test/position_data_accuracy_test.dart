import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/position_data.dart';

String _gga({
  String time = '123456.123456',
  String altitude = '35.2',
  String altitudeUnit = 'M',
  String geoid = '-14.426',
  String geoidUnit = 'M',
}) =>
    '\$GNGGA,$time,3031.7071,N,11421.4181,E,4,18,0.8,'
    '$altitude,$altitudeUnit,$geoid,$geoidUnit,1.0,0000*00';

String _pppsol({
  String time = '20261029013220.123456',
  String latitude = '30.52',
  String longitude = '114.35',
  String height = '21.4437',
  String east = '1.25',
  String north = '-2.5',
  String up = '0.125',
}) =>
    '\$PPPSOL,$time,4,18,$longitude,0.01,$latitude,0.01,$height,0.01,'
    '0,$east,0.03,$north,0.04,$up,0.05,0,0,0,1,2,3*00';

ImuData _imu() => ImuData()
  ..utcYear = 2026
  ..utcMonth = 10
  ..utcDay = 29
  ..utcHour = 1
  ..utcMin = 32
  ..utcSec = 20;

void main() {
  test('GGA keeps original WGS-84 coordinates and ellipsoid height', () {
    final point = parsePositionLine(_gga(), sourcePath: 'gnss.log')!;
    final latitude = 30 + 31.7071 / 60;
    final longitude = 114 + 21.4181 / 60;
    expect(point.type, PointType.gga);
    expect(point.wgs84Latitude, closeTo(latitude, 1e-12));
    expect(point.wgs84Longitude, closeTo(longitude, 1e-12));
    expect((point.location.latitude - latitude).abs(), greaterThan(1e-4));
    expect((point.location.longitude - longitude).abs(), greaterThan(1e-4));
    expect(point.ellipsoidHeight, closeTo(20.774, 1e-12));
    expect(point.utcSecondsOfDay, closeTo(45296.123456, 1e-9));
    expect(point.utcDateTime, isNull);
    expect(point.velocityEast, isNull);
    expect(point.velocityNorth, isNull);
    expect(point.velocityUp, isNull);
    expect(point.sourcePath, 'gnss.log');
  });

  test('GGA height requires both finite measurements and metre units', () {
    for (final line in [
      _gga(altitude: ''),
      _gga(altitude: 'NaN'),
      _gga(geoid: ''),
      _gga(geoid: 'Infinity'),
      _gga(altitudeUnit: 'F'),
      _gga(geoidUnit: ''),
    ]) {
      expect(parsePositionLine(line)!.ellipsoidHeight, isNull, reason: line);
    }
    expect(parsePositionLine(_gga(geoid: '0'))!.ellipsoidHeight, 35.2);
  });

  test('PPPSOL keeps raw position, ENU velocity and full UTC microseconds', () {
    final point = parsePositionLine(_pppsol())!;
    expect(point.wgs84Latitude, 30.52);
    expect(point.wgs84Longitude, 114.35);
    expect(point.ellipsoidHeight, 21.4437);
    expect(point.velocityEast, 1.25);
    expect(point.velocityNorth, -2.5);
    expect(point.velocityUp, 0.125);
    expect(point.utcDateTime, DateTime.utc(2026, 10, 29, 1, 32, 20, 123, 456));
    expect(point.utcSecondsOfDay, closeTo(5540.123456, 1e-9));
    expect(point.location.latitude, isNot(point.wgs84Latitude));
  });

  test('missing PPPSOL optional channels stay unavailable for accuracy', () {
    final point = parsePositionLine(
      _pppsol(height: '', east: '', north: 'NaN', up: 'Infinity'),
    )!;
    expect(point.ellipsoidHeight, isNull);
    expect(point.velocityEast, isNull);
    expect(point.velocityNorth, isNull);
    expect(point.velocityUp, isNull);
    expect(parsePositionLine(_pppsol(east: '0'))!.velocityEast, 0);
  });

  test('invalid or missing PPPSOL coordinates are rejected', () {
    for (final line in [
      _pppsol(latitude: ''),
      _pppsol(longitude: 'bad'),
      _pppsol(latitude: 'NaN'),
      _pppsol(longitude: 'Infinity'),
      _pppsol(latitude: '90.01'),
      _pppsol(longitude: '-180.01'),
    ]) {
      expect(parsePositionLine(line), isNull, reason: line);
    }
  });

  test(
    'UTC parsing validates calendar and time fields without normalization',
    () {
      expect(parseUtcSecondsOfDay('00:00:00.000001'), 0.000001);
      expect(
        parseUtcSecondsOfDay('235959.999999'),
        closeTo(86399.999999, 1e-9),
      );
      for (final invalid in [
        '240000',
        '126000',
        '123460',
        '-123456',
        '12::34:56',
        '1:23456',
        '12345',
        '123456.NaN',
      ]) {
        expect(parseUtcSecondsOfDay(invalid), isNull, reason: invalid);
      }
      for (final invalid in [
        '20260230013220.1',
        '20261301013220',
        '20261000235959',
        '20261029240000',
        '20261029016000',
        '20261029013260',
      ]) {
        expect(parseCompactUtc(invalid), isNull, reason: invalid);
        expect(parsePositionLine(_pppsol(time: invalid))!.utcDateTime, isNull);
      }
      expect(
        parseCompactUtc('20240229013220'),
        DateTime.utc(2024, 2, 29, 1, 32, 20),
      );
      expect(parsePositionLine(_gga(time: '240000'))!.utcSecondsOfDay, isNull);
    },
  );

  test('IMU UTC keeps usec precision and prefers usec to legacy msec', () {
    final sample = _imu()
      ..utcUsec = 123456
      ..utcMsec = 999;
    expect(
      imuUtcDateTime(sample),
      DateTime.utc(2026, 10, 29, 1, 32, 20, 123, 456),
    );
    sample.utcUsec = null;
    expect(imuUtcDateTime(sample), DateTime.utc(2026, 10, 29, 1, 32, 20, 999));
    sample.utcMsec = null;
    expect(imuUtcDateTime(sample), DateTime.utc(2026, 10, 29, 1, 32, 20));
  });

  test('IMU UTC rejects missing, invalid and overflowing fields', () {
    for (final sample in [
      _imu()..utcYear = null,
      _imu()..utcMonth = 13,
      _imu()..utcDay = 0,
      _imu()..utcHour = -1,
      _imu()..utcMin = 60,
      _imu()..utcSec = 60,
      _imu()..utcUsec = -1,
      _imu()..utcUsec = 1000000,
      _imu()..utcMsec = 1000,
    ]) {
      expect(imuUtcDateTime(sample), isNull);
    }
  });
}
