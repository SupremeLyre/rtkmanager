import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rtkmanager/accuracy_evaluation.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/position_data.dart';
import 'package:rtkmanager/truth_data.dart';

final _start = DateTime.utc(2026, 10, 29, 1);
const _stationaryTestOptions = EvaluationOptions(
  stationarySpeedThresholdMps: 10,
);

TruthSample _truth(
  DateTime time, {
  double? height = 20,
  double? east = 1,
  double? north = 2,
  double? up = 3,
  double? roll = 0,
  double? pitch = 0,
  double? heading = 0,
}) => TruthSample(
  utcTime: time,
  latitude: 30,
  longitude: 114,
  height: height,
  velocityEast: east,
  velocityNorth: north,
  velocityUp: up,
  roll: roll,
  pitch: pitch,
  heading: heading,
);

PositionHistoryPoint _point(
  DateTime? time, {
  String source = 'receiver.log',
  double? latitude = 30,
  double longitude = 114,
  double? height = 20,
  double? east = 1,
  double? north = 2,
  double? up = 3,
  double? roll = 0,
  double? pitch = 0,
  double? heading = 0,
  double? tod,
  PointType type = PointType.imu,
  int status = 4,
  int? gnssState = 4,
  int? fusionState = 4,
  int? startupStage,
}) {
  final imu = ImuData()
    ..roll = roll
    ..pitch = pitch
    ..yaw = heading
    ..gnssState = gnssState
    ..fusionState = fusionState
    ..startupStage = startupStage;
  return PositionHistoryPoint(
    location: const LatLng(31, 115), // Display datum must never enter accuracy.
    status: status,
    isImu: type == PointType.imu,
    type: type,
    sourcePath: source,
    wgs84Latitude: latitude,
    wgs84Longitude: longitude,
    ellipsoidHeight: height,
    velocityEast: east,
    velocityNorth: north,
    velocityUp: up,
    utcDateTime: time,
    utcSecondsOfDay: tod,
    imuData: imu,
  );
}

TruthDataset _dataset(List<TruthSample> samples) =>
    TruthDataset(sourcePath: 'truth.pos', samples: samples);

void main() {
  test('uses raw WGS84 instead of the displayed map coordinates', () {
    final point = _point(_start);
    final result = evaluateAccuracy(
      points: [point],
      truth: _dataset([_truth(_start)]),
      options: const EvaluationOptions(calibrate: false),
    );
    expect(result.records.single.point, same(point));
    expect(result.records.single.rawPosition.norm, closeTo(0, 1e-9));
    expect(
      result.layers.single.statistics['position']!.threeDimensionalRmse,
      closeTo(0, 1e-9),
    );
  });

  test('ENU signs and metre units follow the ECEF tangent basis', () {
    const longitude = 0.00001;
    final point = _point(_start, latitude: 0, longitude: longitude, height: 5);
    final truth = TruthSample(
      utcTime: _start,
      latitude: 0,
      longitude: 0,
      height: 0,
    );
    final result = evaluateAccuracy(
      points: [point],
      truth: _dataset([truth]),
      options: const EvaluationOptions(calibrate: false),
    );
    final error = result.records.single.rawPosition;
    expect(
      error.x,
      closeTo((6378137 + 5) * math.sin(longitude * math.pi / 180), 1e-8),
    );
    expect(error.y, closeTo(0, 1e-8));
    expect(
      error.z,
      closeTo(
        (6378137 + 5) * math.cos(longitude * math.pi / 180) - 6378137,
        1e-8,
      ),
    );
  });

  test(
    'fits fixed offsets independently for each file and keeps raw errors',
    () {
      final times = List.generate(3, (i) => _start.add(Duration(seconds: i)));
      final points = [
        for (final time in times)
          _point(
            time,
            latitude: 30.00001,
            longitude: 114.00002,
            height: 25,
            east: 2,
            north: 0,
            up: 6,
            roll: 1,
            pitch: 2,
            heading: 359,
          ),
        for (final time in times)
          _point(
            time,
            source: 'other.log',
            latitude: 29.99999,
            longitude: 114.00001,
            east: 5,
            north: 2,
            up: 3,
            roll: -2,
            pitch: 3,
            heading: 4,
          ),
      ];
      final result = evaluateAccuracy(
        points: points,
        truth: _dataset(times.map(_truth).toList()),
        options: const EvaluationOptions(
          stableRtkMinDurationSeconds: 0,
          stationarySpeedThresholdMps: 10,
        ),
      );
      expect(result.layers, hasLength(2));
      for (final layer in result.layers) {
        expect(layer.calibration.positionCount, 3);
        expect(layer.calibration.attitudeCount, 1);
        expect(
          layer.rawStatistics['position']!.horizontalRmse,
          greaterThan(0.1),
        );
        expect(
          layer.statistics['position']!.threeDimensionalRmse,
          closeTo(0, 1e-8),
        );
        expect(
          layer.statistics['velocity']!.threeDimensionalRmse,
          closeTo(0, 1e-10),
        );
        expect(
          layer.statistics['attitude']!.threeDimensionalRmse,
          closeTo(0, 1e-8),
        );
      }
      expect(result.layers.first.calibration.velocityOffset.x, 1);
      expect(result.layers.last.calibration.velocityOffset.x, 4);
      expect(
        result.layers.first.calibration.attitudeOffset.z,
        closeTo(-1, 1e-8),
      );
      expect(
        result.records.every(
          (entry) => identical(entry.point, points[entry.pointIndex]),
        ),
        isTrue,
      );
    },
  );

  test('a calibration window is fitted once and applied to later epochs', () {
    final later = _start.add(const Duration(seconds: 1));
    final last = _start.add(const Duration(seconds: 2));
    final result = evaluateAccuracy(
      points: [
        _point(_start, east: 2),
        _point(later, east: 2),
        _point(last, east: 4),
      ],
      truth: _dataset([_truth(_start), _truth(later), _truth(last)]),
      options: EvaluationOptions(
        calibrationStart: _start,
        calibrationEnd: later,
        stableRtkMinDurationSeconds: 0,
        stationarySpeedThresholdMps: 10,
      ),
    );
    expect(result.layers.single.calibration.velocityCount, 2);
    expect(result.records.first.correctedVelocity.x, closeTo(0, 1e-10));
    expect(result.records.last.correctedVelocity.x, closeTo(2, 1e-10));
    expect(
      result.layers.single.statistics['velocity']!.x.rmse,
      closeTo(math.sqrt(4 / 3), 1e-10),
    );
  });

  test(
    'empty calibration window keeps errors and exposes unavailable offsets',
    () {
      final result = evaluateAccuracy(
        points: [_point(_start, east: 2)],
        truth: _dataset([_truth(_start)]),
        options: EvaluationOptions(
          calibrationStart: _start.add(const Duration(hours: 1)),
          stableRtkMinDurationSeconds: 0,
          stationarySpeedThresholdMps: 10,
        ),
      );
      expect(result.layers.single.calibration.velocityCount, 0);
      expect(result.layers.single.calibration.velocityOffset.x, isNull);
      expect(result.records.single.correctedVelocity.x, 1);
    },
  );

  test('interpolates reference channels and heading over the shortest arc', () {
    final middle = _start.add(const Duration(seconds: 1));
    final result = evaluateAccuracy(
      points: [_point(middle, east: 2, heading: 0)],
      truth: _dataset([
        _truth(_start, east: 1, heading: 350),
        _truth(_start.add(const Duration(seconds: 2)), east: 3, heading: 10),
      ]),
      options: const EvaluationOptions(calibrate: false),
    );
    expect(result.records.single.truth.heading, closeTo(0, 1e-9));
    expect(result.records.single.rawVelocity.x, closeTo(0, 1e-9));
    expect(result.records.single.rawAttitude.z, closeTo(0, 1e-9));
  });

  test(
    'refuses extrapolation, large gaps, and same-clock epochs on another date',
    () {
      final end = _start.add(const Duration(seconds: 10));
      final result = evaluateAccuracy(
        points: [
          _point(_start.subtract(const Duration(microseconds: 1))),
          _point(_start.add(const Duration(seconds: 5))),
          _point(end),
          _point(_start.add(const Duration(days: 1)), tod: 3600),
        ],
        truth: _dataset([_truth(_start), _truth(end)]),
      );
      expect(result.records, hasLength(1));
      expect(result.records.single.pointIndex, 2);
      expect(result.unmatchedCount, 3);
      expect(result.unmatchedReasons.values.reduce((a, b) => a + b), 3);
    },
  );

  test('user time offset shifts UTC matching before interpolation', () {
    final time = _start.add(const Duration(seconds: 1));
    final result = evaluateAccuracy(
      points: [_point(_start)],
      truth: _dataset([_truth(time)]),
      options: const EvaluationOptions(timeOffsetSeconds: 1),
    );
    expect(result.records.single.utcTime, time);
  });

  test('native GPS timestamp takes priority over legacy IMU UTC metadata', () {
    final point = _point(_start);
    final imu = point.imuData!
      ..gpsWeek = 2442
      ..gpsTowNanos = 351158000000000;
    final native = gpsTimeToUtc(imu.gpsWeek!, imu.gpsTowNanos! / 1e9);
    final result = evaluateAccuracy(
      points: [point],
      truth: _dataset([_truth(native)]),
    );
    expect(result.records.single.utcTime, native);
  });

  test('a malformed absolute PPP date cannot be inferred as a GGA date', () {
    final point = _point(null, type: PointType.pppsol, tod: 3600);
    final result = evaluateAccuracy(
      points: [point],
      truth: _dataset([_truth(_start)]),
    );
    expect(result.records, isEmpty);
    expect(result.unmatchedCount, 1);
  });

  test('GGA infers one date and preserves midnight rollover', () {
    final before = DateTime.utc(2026, 10, 29, 23, 59, 59);
    final after = before.add(const Duration(seconds: 2));
    final result = evaluateAccuracy(
      points: [
        _point(null, tod: 86399.5, type: PointType.gga),
        _point(null, tod: 0.5, type: PointType.gga),
      ],
      truth: _dataset([_truth(before), _truth(after)]),
    );
    expect(result.records, hasLength(2));
    expect(
      result.records.first.utcTime,
      before.add(const Duration(milliseconds: 500)),
    );
    expect(
      result.records.last.utcTime,
      DateTime.utc(2026, 10, 30, 0, 0, 0, 500),
    );
  });

  test(
    'GGA refuses an ambiguous date until the date is explicitly selected',
    () {
      final following = _start.add(const Duration(days: 1));
      final truth = _dataset([_truth(_start), _truth(following)]);
      final point = _point(null, tod: 3600, type: PointType.gga);
      final ambiguous = evaluateAccuracy(points: [point], truth: truth);
      expect(ambiguous.records, isEmpty);
      expect(ambiguous.unmatchedCount, 1);
      final selected = evaluateAccuracy(
        points: [point],
        truth: truth,
        options: EvaluationOptions(ggaDate: following),
      );
      expect(selected.records.single.utcTime, following);
    },
  );

  test('missing reference channels stay missing in errors and statistics', () {
    final result = evaluateAccuracy(
      points: [_point(_start)],
      truth: _dataset([
        _truth(
          _start,
          height: null,
          east: null,
          north: null,
          up: null,
          roll: null,
          pitch: null,
          heading: null,
        ),
      ]),
    );
    final record = result.records.single;
    expect(record.rawPosition.z, isNull);
    expect(record.correctedPosition.z, isNull);
    expect(record.rawVelocity.x, isNull);
    expect(record.rawAttitude.z, isNull);
    expect(result.layers.single.statistics['position']!.z.count, 0);
    expect(
      result.layers.single.statistics['position']!.threeDimensionalRmse,
      isNull,
    );
    expect(result.layers.single.statistics['velocity']!.x.rmse, isNull);
    expect(result.layers.single.calibration.attitudeCount, 0);
  });

  test(
    'installation rotation correction handles coupled Euler orientations',
    () {
      final times = List.generate(4, (i) => _start.add(Duration(seconds: i)));
      final references = [
        (0.0, 0.0, 350.0),
        (20.0, -15.0, 40.0),
        (-10.0, 30.0, 150.0),
        (35.0, -20.0, 260.0),
      ];
      final installation = _rotation(5, -8, 12);
      final samples = <TruthSample>[];
      final points = <PositionHistoryPoint>[];
      for (var i = 0; i < times.length; i++) {
        final (r, p, h) = references[i];
        final solution = _euler(_multiply(_rotation(r, p, h), installation));
        samples.add(_truth(times[i], roll: r, pitch: p, heading: h));
        points.add(
          _point(
            times[i],
            roll: solution.$1,
            pitch: solution.$2,
            heading: solution.$3,
          ),
        );
      }
      final result = evaluateAccuracy(
        points: points,
        truth: _dataset(samples),
        options: const EvaluationOptions(
          stableRtkMinDurationSeconds: 0,
          stationarySpeedThresholdMps: 10,
        ),
      );
      final fitted = result.layers.single.calibration.attitudeOffset;
      expect(
        result.layers.single.calibration.attitudeReferenceTime,
        times.last,
      );
      expect(result.layers.single.calibration.attitudeCount, 1);
      expect(fitted.x, closeTo(5, 1e-8));
      expect(fitted.y, closeTo(-8, 1e-8));
      expect(fitted.z, closeTo(12, 1e-8));
      for (final record in result.records) {
        expect(record.correctedAttitude.norm, closeTo(0, 1e-8));
      }
    },
  );

  test(
    'isolate remapping preserves source indices including unmatched points',
    () {
      final points = [
        _point(_start.subtract(const Duration(seconds: 1))),
        _point(_start),
      ];
      final result = evaluateAccuracy(
        points: points,
        truth: _dataset([_truth(_start)]),
      );
      final originals = [_point(_start), _point(_start)];
      final remapped = result.withPoints(originals);
      expect(remapped.records.single.pointIndex, 1);
      expect(remapped.records.single.point, same(originals[1]));
      expect(
        remapped.records.single,
        same(remapped.layers.single.records.single),
      );
    },
  );

  test(
    'one complete stable stationary segment fits offsets for every epoch',
    () {
      final times = List.generate(15, (i) => _start.add(Duration(seconds: i)));
      final points = [
        for (var i = 0; i < times.length; i++)
          _point(
            times[i],
            east: i < 13
                ? 2
                : i == 13
                ? 8
                : 10,
            status: i == 13
                ? 5
                : i == 14
                ? 1
                : 4,
            gnssState: i == 13
                ? 5
                : i == 14
                ? 1
                : 4,
          ),
      ];
      final result = evaluateAccuracy(
        points: points,
        truth: _dataset(times.map(_truth).toList()),
        options: _stationaryTestOptions,
      );
      final calibration = result.layers.single.calibration;
      expect(result.records, hasLength(15));
      expect(calibration.stableRtkCount, 13);
      expect(calibration.velocityCount, 13);
      expect(calibration.velocityOffset.x, closeTo(1, 1e-10));
      expect(calibration.applied, isTrue);
      expect(calibration.unavailableReason, isNull);
      expect(calibration.intervalStart, times.first);
      expect(calibration.intervalEnd, times[12]);
      expect(result.records.first.correctedVelocity.x, closeTo(0, 1e-10));
      expect(result.records[10].correctedVelocity.x, closeTo(0, 1e-10));
      expect(result.records[13].correctedVelocity.x, closeTo(6, 1e-10));
      expect(result.records.last.correctedVelocity.x, closeTo(8, 1e-10));
    },
  );

  test('a nonfixed epoch without a truth match still resets RTK stability', () {
    final times = List.generate(22, (i) => _start.add(Duration(seconds: i)));
    final result = evaluateAccuracy(
      points: [
        for (var i = 0; i < times.length; i++)
          _point(
            times[i],
            east: i < 10 ? 50 : 2,
            gnssState: i == 10 ? 5 : 4,
            status: i == 10 ? 5 : 4,
          ),
      ],
      truth: _dataset([
        for (var i = 0; i < times.length; i++)
          if (i != 10) _truth(times[i]),
      ]),
      options: const EvaluationOptions(
        maxInterpolationGapSeconds: 0.1,
        stationarySpeedThresholdMps: 10,
      ),
    );
    expect(result.records, hasLength(21));
    expect(result.unmatchedCount, 1);
    expect(result.layers.single.calibration.stableRtkCount, 11);
    expect(
      result.layers.single.calibration.velocityOffset.x,
      closeTo(1, 1e-10),
    );
  });

  test(
    'a nonfixed epoch with invalid coordinates still resets RTK stability',
    () {
      final times = List.generate(13, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          for (var i = 0; i < times.length; i++)
            _point(
              times[i],
              latitude: i == 5 ? null : 30,
              gnssState: i == 5 ? 5 : 4,
              status: i == 5 ? 5 : 4,
            ),
        ],
        truth: _dataset(times.map(_truth).toList()),
        options: _stationaryTestOptions,
      );
      expect(result.records, hasLength(12));
      expect(result.unmatchedCount, 1);
      expect(result.layers.single.calibration.stableRtkCount, 0);
      expect(result.layers.single.calibration.positionCount, 0);
    },
  );

  test(
    'sampling gaps split stationary segments and only the first is fitted',
    () {
      final seconds = [
        for (var i = 0; i <= 10; i++) i,
        for (var i = 13; i <= 23; i++) i,
      ];
      final times = seconds
          .map((i) => _start.add(Duration(seconds: i)))
          .toList();
      final result = evaluateAccuracy(
        points: [for (final time in times) _point(time, east: 2)],
        truth: _dataset(times.map(_truth).toList()),
        options: _stationaryTestOptions,
      );
      expect(result.records, hasLength(22));
      expect(result.layers.single.calibration.stableRtkCount, 11);
      expect(result.layers.single.calibration.intervalEnd, times[10]);
      final strictGap = evaluateAccuracy(
        points: [for (final time in times) _point(time, east: 2)],
        truth: _dataset(times.map(_truth).toList()),
        options: const EvaluationOptions(
          stableRtkMaxGapSeconds: 0.5,
          stationarySpeedThresholdMps: 10,
        ),
      );
      expect(strictGap.layers.single.calibration.stableRtkCount, 0);
      expect(strictGap.layers.single.calibration.velocityOffset.x, isNull);
      expect(strictGap.layers.single.calibration.unavailableReason, isNotEmpty);
    },
  );

  test('duplicate timestamps cannot manufacture a stable RTK duration', () {
    final times = List.generate(10, (i) => _start.add(Duration(seconds: i)));
    final points = [
      for (final time in times) _point(time, east: 2),
      for (var i = 0; i < 100; i++) _point(times[5], east: 2),
    ];
    final result = evaluateAccuracy(
      points: points,
      truth: _dataset(times.map(_truth).toList()),
      options: _stationaryTestOptions,
    );
    expect(result.records, hasLength(110));
    expect(result.layers.single.calibration.stableRtkCount, 0);
    expect(result.layers.single.calibration.positionCount, 0);
    expect(result.layers.single.calibration.velocityOffset.x, isNull);
    expect(
      result.records.every(
        (record) => record.correctedVelocity.x == record.rawVelocity.x,
      ),
      isTrue,
    );
  });

  test(
    'conflicting states at one timestamp conservatively split a segment',
    () {
      final times = List.generate(16, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          for (final time in times) _point(time),
          _point(times[5], status: 5, gnssState: 5),
        ],
        truth: _dataset(times.map(_truth).toList()),
        options: _stationaryTestOptions,
      );
      expect(result.records, hasLength(17));
      expect(result.layers.single.calibration.stableRtkCount, 0);
      expect(result.layers.single.calibration.positionCount, 0);
    },
  );

  test(
    'conflicting duplicate positions cannot enter the first stationary segment',
    () {
      final times = List.generate(12, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          _point(times[0], type: PointType.pppsol, gnssState: null),
          _point(
            times[0],
            type: PointType.pppsol,
            gnssState: null,
            latitude: 30.00001,
          ),
          for (final time in times.skip(1))
            _point(time, type: PointType.pppsol, gnssState: null),
        ],
        truth: _dataset([
          for (final time in times) _truth(time, east: 0, north: 0, up: 0),
        ]),
      );
      expect(result.records, hasLength(13));
      final calibration = result.layers.single.calibration;
      expect(calibration.stableRtkCount, 11);
      expect(calibration.intervalStart, times[1]);
      expect(calibration.intervalEnd, times[11]);
      expect(calibration.positionOffset.norm, closeTo(0, 1e-9));
    },
  );

  test(
    'the explicit window restricts the stationary segment before duration checks',
    () {
      final times = List.generate(13, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          for (var i = 0; i < times.length; i++)
            _point(times[i], type: PointType.gga, gnssState: null, east: 2),
        ],
        truth: _dataset(times.map(_truth).toList()),
        options: EvaluationOptions(
          calibrationStart: times[0],
          calibrationEnd: times[10],
          stationarySpeedThresholdMps: 10,
        ),
      );
      expect(result.records, hasLength(13));
      expect(result.layers.single.calibration.stableRtkCount, 11);
      expect(result.layers.single.calibration.intervalStart, times[0]);
      expect(result.layers.single.calibration.intervalEnd, times[10]);
      expect(
        result.layers.single.calibration.velocityOffset.x,
        closeTo(1, 1e-10),
      );
      final outside = evaluateAccuracy(
        points: [for (final time in times) _point(time, east: 2)],
        truth: _dataset(times.map(_truth).toList()),
        options: EvaluationOptions(
          calibrationStart: times[0],
          calibrationEnd: times[9],
          stationarySpeedThresholdMps: 10,
        ),
      );
      expect(outside.layers.single.calibration.stableRtkCount, 0);
      expect(outside.layers.single.calibration.unavailableReason, isNotEmpty);
      expect(outside.layers.single.calibration.velocityOffset.x, isNull);
    },
  );

  test(
    'stable RTK candidates never transfer between source files or types',
    () {
      final times = List.generate(13, (i) => _start.add(Duration(seconds: i)));
      final points = [
        for (final time in times)
          _point(
            time,
            source: 'mixed.log',
            type: PointType.gga,
            gnssState: null,
            east: 2,
          ),
        for (final time in times.take(10))
          _point(time, source: 'short.log', east: 50),
        for (final time in times.take(10))
          _point(time, source: 'mixed.log', east: 50),
      ];
      final result = evaluateAccuracy(
        points: points,
        truth: _dataset(times.map(_truth).toList()),
        options: _stationaryTestOptions,
      );
      expect(result.records, hasLength(33));
      expect(result.layers, hasLength(3));
      expect(result.layers.first.calibration.stableRtkCount, 13);
      expect(
        result.layers.first.calibration.velocityOffset.x,
        closeTo(1, 1e-10),
      );
      for (final layer in result.layers.skip(1)) {
        expect(layer.calibration.stableRtkCount, 0);
        expect(layer.calibration.positionCount, 0);
        expect(layer.calibration.velocityOffset.x, isNull);
        expect(
          layer.records.first.correctedVelocity.x,
          layer.records.first.rawVelocity.x,
        );
      }
    },
  );

  test('stable stationary PPP status 4 calibrates without any RTK flag', () {
    final times = List.generate(13, (i) => _start.add(Duration(seconds: i)));
    final result = evaluateAccuracy(
      points: [
        for (final time in times)
          _point(time, type: PointType.pppsol, east: 2, gnssState: null),
      ],
      truth: _dataset(times.map(_truth).toList()),
      options: _stationaryTestOptions,
    );
    expect(result.records, hasLength(13));
    final calibration = result.layers.single.calibration;
    expect(calibration.stableRtkCount, 13);
    expect(calibration.positionCount, 13);
    expect(calibration.velocityCount, 13);
    expect(calibration.applied, isTrue);
    expect(calibration.unavailableReason, isNull);
    expect(calibration.intervalStart, times.first);
    expect(calibration.intervalEnd, times.last);
    expect(result.records.last.correctedVelocity.x, closeTo(0, 1e-10));
  });

  test('two distinct static PPP epochs calibrate but SPP does not', () {
    final times = [_start, _start.add(const Duration(seconds: 1))];
    final truth = _dataset([
      for (final time in times) _truth(time, east: 0, north: 0, up: 0),
    ]);
    for (final status in [4, 3]) {
      final result = evaluateAccuracy(
        points: [
          for (final time in times)
            _point(
              time,
              type: PointType.pppsol,
              gnssState: null,
              status: status,
              east: 0.2,
              north: 0,
              up: 0,
            ),
        ],
        truth: truth,
        options: const EvaluationOptions(stableRtkMinDurationSeconds: 0),
      );
      expect(result.records, hasLength(2));
      expect(result.layers.single.calibration.applied, status == 4);
      expect(
        result.layers.single.calibration.stableRtkCount,
        status == 4 ? 2 : 0,
      );
      expect(
        result.records.last.correctedVelocity.x,
        status == 4 ? closeTo(0, 1e-10) : closeTo(0.2, 1e-10),
      );
    }
  });

  test(
    'one stationary segment gives the same constant correction to every epoch',
    () {
      final times = List.generate(30, (i) => _start.add(Duration(seconds: i)));
      final samples = <TruthSample>[];
      final points = <PositionHistoryPoint>[];
      for (var i = 0; i < times.length; i++) {
        final moving = i >= 11 && i <= 17;
        final laterStop = i >= 18;
        final distance = i <= 10
            ? 0
            : i <= 17
            ? i - 10
            : 7;
        final latitude = 30 + distance * 0.0001;
        final longitude = 114 + distance * 0.00005;
        samples.add(
          TruthSample(
            utcTime: times[i],
            latitude: latitude,
            longitude: longitude,
            height: 20,
            velocityEast: moving ? 1 : 0,
            velocityNorth: 0,
            velocityUp: 0,
            roll: 0,
            pitch: 0,
            heading: 0,
          ),
        );
        points.add(
          _point(
            times[i],
            latitude:
                latitude +
                (laterStop
                    ? 0.001
                    : moving
                    ? (i - 9) * 0.00001
                    : 0.00001),
            longitude: longitude + (laterStop ? 0.001 : 0.00002),
            height: laterStop ? 25 : 22,
            east: moving
                ? 1.2 + (i - 10) * 0.1
                : laterStop
                ? 3
                : 0.2,
            north: laterStop ? -4 : -0.1,
            up: laterStop ? 2 : 0.3,
            roll: laterStop ? 8 : 2,
            pitch: laterStop ? 5 : -1,
            heading: laterStop ? 20 : 3,
          ),
        );
      }
      final result = evaluateAccuracy(points: points, truth: _dataset(samples));
      final calibration = result.layers.single.calibration;
      expect(result.records, hasLength(30));
      expect(calibration.stableRtkCount, 11);
      expect(calibration.intervalStart, times[0]);
      expect(calibration.intervalEnd, times[10]);
      expect(calibration.velocityOffset.x, closeTo(0.2, 1e-10));
      expect(calibration.velocityOffset.y, closeTo(-0.1, 1e-10));
      expect(calibration.velocityOffset.z, closeTo(0.3, 1e-10));
      expect(calibration.attitudeReferenceTime, times.last);
      expect(calibration.attitudeOffset.x, closeTo(8, 1e-8));
      expect(calibration.attitudeOffset.y, closeTo(5, 1e-8));
      expect(calibration.attitudeOffset.z, closeTo(20, 1e-8));
      for (final record in result.records) {
        expect(
          record.rawPosition.x! - record.correctedPosition.x!,
          closeTo(calibration.positionOffset.x!, 1e-9),
        );
        expect(
          record.rawPosition.y! - record.correctedPosition.y!,
          closeTo(calibration.positionOffset.y!, 1e-9),
        );
        expect(
          record.rawPosition.z! - record.correctedPosition.z!,
          closeTo(calibration.positionOffset.z!, 1e-9),
        );
        expect(
          record.rawVelocity.x! - record.correctedVelocity.x!,
          closeTo(0.2, 1e-10),
        );
        expect(
          record.rawVelocity.y! - record.correctedVelocity.y!,
          closeTo(-0.1, 1e-10),
        );
        expect(
          record.rawVelocity.z! - record.correctedVelocity.z!,
          closeTo(0.3, 1e-10),
        );
      }
      expect(result.records.first.correctedPosition.norm, closeTo(0, 1e-8));
      expect(result.records.last.correctedPosition.horizontal, greaterThan(10));
      expect(result.records.last.correctedVelocity.norm, greaterThan(1));
      expect(result.records.first.correctedAttitude.norm, greaterThan(5));
      expect(result.records.last.correctedAttitude.norm, closeTo(0, 1e-8));
    },
  );

  test(
    'GGA without velocity uses reference position motion to establish rest',
    () {
      final times = List.generate(13, (i) => _start.add(Duration(seconds: i)));
      final samples = [
        for (final time in times)
          _truth(time, east: null, north: null, up: null),
      ];
      final result = evaluateAccuracy(
        points: [
          for (final time in times)
            _point(
              time,
              type: PointType.gga,
              gnssState: null,
              east: null,
              north: null,
              up: null,
            ),
        ],
        truth: _dataset(samples),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.applied, isTrue);
      expect(calibration.positionCount, 13);
      expect(calibration.velocityCount, 0);
      expect(calibration.intervalStart, times.first);
      expect(calibration.intervalEnd, times.last);
    },
  );

  test('moving truth cannot supply a stationary calibration segment', () {
    final times = List.generate(13, (i) => _start.add(Duration(seconds: i)));
    final points = [for (final time in times) _point(time)];
    final withVelocity = evaluateAccuracy(
      points: points,
      truth: _dataset([
        for (final time in times) _truth(time, east: 1, north: 0, up: 0),
      ]),
    );
    expect(withVelocity.layers.single.calibration.positionCount, 0);
    final withoutVelocity = evaluateAccuracy(
      points: points,
      truth: _dataset([
        for (var i = 0; i < times.length; i++)
          TruthSample(
            utcTime: times[i],
            latitude: 30 + i * 0.00001,
            longitude: 114,
          ),
      ]),
    );
    expect(withoutVelocity.layers.single.calibration.positionCount, 0);
  });

  test(
    'solution position stability is required even with stationary truth',
    () {
      final times = List.generate(13, (i) => _start.add(Duration(seconds: i)));
      final points = [
        for (var i = 0; i < times.length; i++)
          _point(times[i], latitude: 30 + (i % 2) * 0.00001),
      ];
      final truth = _dataset([
        for (final time in times) _truth(time, east: 0, north: 0, up: 0),
      ]);
      final strict = evaluateAccuracy(points: points, truth: truth);
      expect(strict.layers.single.calibration.positionCount, 0);
      final relaxed = evaluateAccuracy(
        points: points,
        truth: truth,
        options: const EvaluationOptions(stablePositionThresholdMeters: 2),
      );
      expect(relaxed.layers.single.calibration.positionCount, 13);
    },
  );

  test(
    'a short early rest does not block the first later qualifying interval',
    () {
      final times = List.generate(19, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          for (var i = 0; i < times.length; i++)
            _point(times[i], east: i < 4 ? 50 : 2),
        ],
        truth: _dataset([
          for (var i = 0; i < times.length; i++)
            _truth(times[i], east: i >= 4 && i <= 6 ? 1 : 0, north: 0, up: 0),
        ]),
      );
      expect(result.layers.single.calibration.intervalStart, times[7]);
      expect(result.layers.single.calibration.intervalEnd, times[18]);
      expect(result.layers.single.calibration.stableRtkCount, 12);
      expect(
        result.layers.single.calibration.velocityOffset.x,
        closeTo(2, 1e-10),
      );
    },
  );

  test(
    'one unique epoch never estimates a system bias even with zero duration',
    () {
      final result = evaluateAccuracy(
        points: [_point(_start), _point(_start)],
        truth: _dataset([_truth(_start, east: 0, north: 0, up: 0)]),
        options: const EvaluationOptions(stableRtkMinDurationSeconds: 0),
      );
      expect(result.records, hasLength(2));
      expect(result.layers.single.calibration.positionCount, 0);
      expect(result.layers.single.calibration.intervalStart, isNull);
      expect(result.layers.single.calibration.intervalEnd, isNull);
    },
  );

  test(
    'IMU calibration requires native fixed GNSS status without a fallback',
    () {
      final times = List.generate(13, (i) => _start.add(Duration(seconds: i)));
      for (final nativeStatus in <int?>[null, 5, 4]) {
        final result = evaluateAccuracy(
          points: [
            for (final time in times)
              _point(
                time,
                east: 2,
                gnssState: nativeStatus,
                status: nativeStatus == 4 ? 5 : 4,
              ),
          ],
          truth: _dataset(times.map(_truth).toList()),
          options: _stationaryTestOptions,
        );
        expect(result.records, hasLength(13));
        final calibration = result.layers.single.calibration;
        expect(calibration.stableRtkCount, nativeStatus == 4 ? 13 : 0);
        expect(calibration.applied, nativeStatus == 4);
        if (nativeStatus != 4) {
          expect(calibration.velocityOffset.x, isNull);
          expect(calibration.unavailableReason, isNotEmpty);
        }
      }
    },
  );

  test(
    'the last complete FIX corrects heading without counting initialization epochs',
    () {
      final times = List.generate(17, (i) => _start.add(Duration(seconds: i)));
      final points = [
        for (var i = 0; i < times.length; i++)
          _point(
            times[i],
            east: i <= 10 ? 0 : 1,
            north: 0,
            up: 0,
            roll: 11,
            pitch: -6,
            heading: i <= 10 ? 0 : 121,
            fusionState: i <= 10 ? 1 : 4,
          ),
      ];
      final result = evaluateAccuracy(
        points: points,
        truth: _dataset([
          for (var i = 0; i < times.length; i++)
            _truth(
              times[i],
              east: i <= 10 ? 0 : 1,
              north: 0,
              up: 0,
              roll: 10,
              pitch: -8,
              heading: 120,
            ),
        ]),
      );
      final layer = result.layers.single;
      final calibration = layer.calibration;
      expect(result.records, hasLength(17));
      expect(calibration.intervalStart, times.first);
      expect(calibration.intervalEnd, times[10]);
      expect(calibration.tiltCount, 1);
      expect(calibration.headingCount, 1);
      expect(calibration.attitudeCount, 1);
      expect(calibration.attitudeReferenceTime, times.last);
      expect(calibration.headingBias, closeTo(1, 1e-9));
      expect(calibration.headingBiasCount, 1);
      for (var i = 0; i < result.records.length; i++) {
        final record = result.records[i];
        expect(record.rawAttitude.x, closeTo(1, 1e-9));
        expect(record.rawAttitude.y, closeTo(2, 1e-9));
        expect(record.correctedAttitude.x, closeTo(0, 1e-9));
        expect(record.correctedAttitude.y, closeTo(0, 1e-9));
        if (i <= 10) {
          expect(record.rawAttitude.z, isNull);
          expect(record.correctedAttitude.z, isNull);
          expect(record.correctedAttitude.norm, isNull);
        } else {
          expect(record.rawAttitude.z, closeTo(1, 1e-9));
          expect(record.correctedAttitude.z, closeTo(0, 1e-8));
        }
      }
      expect(layer.rawStatistics['attitude']!.x.count, 17);
      expect(layer.statistics['attitude']!.x.count, 17);
      expect(layer.rawStatistics['attitude']!.z.count, 6);
      expect(layer.statistics['attitude']!.z.count, 6);
      expect(layer.rawStatistics['attitude']!.z.rmse, closeTo(1, 1e-9));
      expect(layer.statistics['attitude']!.z.rmse, closeTo(0, 1e-8));
    },
  );

  test('fusion readiness masks only the available attitude components', () {
    final states = <int?>[1, 4, 5, 0, 2, 3, null];
    final times = List.generate(
      states.length,
      (i) => _start.add(Duration(seconds: i)),
    );
    final result = evaluateAccuracy(
      points: [
        for (var i = 0; i < states.length; i++)
          _point(
            times[i],
            roll: 1,
            pitch: 2,
            heading: 31,
            fusionState: states[i],
            gnssState: states[i] == 5 ? null : 4,
          ),
      ],
      truth: _dataset([for (final time in times) _truth(time, heading: 30)]),
      options: const EvaluationOptions(calibrate: false),
    );
    expect(result.records, hasLength(states.length));
    for (var i = 0; i < states.length; i++) {
      final error = result.records[i].rawAttitude;
      if (i <= 2) {
        expect(error.x, closeTo(1, 1e-9));
        expect(error.y, closeTo(2, 1e-9));
      } else {
        expect(error.x, isNull);
        expect(error.y, isNull);
      }
      if (states[i] == 4 || states[i] == 5) {
        expect(error.z, closeTo(1, 1e-9));
      } else {
        expect(error.z, isNull);
      }
    }
    final statistics = result.layers.single.rawStatistics['attitude']!;
    expect(statistics.x.count, 3);
    expect(statistics.y.count, 3);
    expect(statistics.z.count, 2);
    expect(statistics.z.rmse, closeTo(1, 1e-9));
  });

  test(
    'horizontal-only correction uses the last FIX offset with angular wrapping',
    () {
      final times = [_start, _start.add(const Duration(seconds: 1))];
      final result = evaluateAccuracy(
        points: [
          _point(times[0], roll: 179, pitch: 1, fusionState: 1),
          _point(times[1], roll: -179, pitch: 1, fusionState: 1),
        ],
        truth: _dataset([
          for (final time in times) _truth(time, east: 0, north: 0, up: 0),
        ]),
        options: const EvaluationOptions(stableRtkMinDurationSeconds: 0),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.tiltCount, 1);
      expect(calibration.headingCount, 0);
      expect(calibration.attitudeReferenceTime, times.last);
      expect(calibration.attitudeOffset.x, closeTo(-179, 1e-9));
      expect(calibration.attitudeOffset.y, closeTo(1, 1e-9));
      expect(calibration.attitudeOffset.z, isNull);
      expect(
        result.layers.single.statistics['attitude']!.x.rmse,
        closeTo(math.sqrt(2), 1e-9),
      );
      expect(
        result.layers.single.statistics['attitude']!.y.rmse,
        closeTo(0, 1e-9),
      );
    },
  );

  test(
    'full installation uses the last heading-ready FIX beyond the static interval',
    () {
      final times = List.generate(15, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          for (var i = 0; i < times.length; i++)
            _point(
              times[i],
              roll: 1,
              pitch: 2,
              heading: i < 11 ? 0 : 123,
              fusionState: i < 11 ? 1 : 4,
            ),
        ],
        truth: _dataset([
          for (var i = 0; i < times.length; i++)
            _truth(
              times[i],
              east: i <= 12 ? 0 : 1,
              north: 0,
              up: 0,
              heading: 120,
            ),
        ]),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.intervalEnd, times[12]);
      expect(calibration.tiltCount, 1);
      expect(calibration.headingCount, 1);
      expect(calibration.attitudeCount, 1);
      expect(calibration.attitudeReferenceTime, times.last);
      expect(calibration.attitudeOffset.x, closeTo(1, 1e-8));
      expect(calibration.attitudeOffset.y, closeTo(2, 1e-8));
      expect(calibration.attitudeOffset.z, closeTo(3, 1e-8));
      for (final record in result.records.take(11)) {
        expect(record.correctedAttitude.z, isNull);
      }
      for (final record in result.records.skip(11)) {
        expect(record.correctedAttitude.norm, closeTo(0, 1e-8));
      }
      expect(result.layers.single.statistics['attitude']!.z.count, 4);
      expect(
        result.layers.single.statistics['attitude']!.z.rmse,
        closeTo(0, 1e-8),
      );
    },
  );

  test('startup stage overrides fusion state for attitude readiness', () {
    final states = <(int?, int)>[
      (4, 2),
      (1, 3),
      (4, 0),
      (4, 99),
      (5, 1),
      (null, 3),
    ];
    final times = List.generate(
      states.length,
      (i) => _start.add(Duration(seconds: i)),
    );
    final result = evaluateAccuracy(
      points: [
        for (var i = 0; i < states.length; i++)
          _point(
            times[i],
            roll: 1,
            pitch: 2,
            heading: 31,
            fusionState: states[i].$1,
            startupStage: states[i].$2,
          ),
      ],
      truth: _dataset([for (final time in times) _truth(time, heading: 30)]),
      options: const EvaluationOptions(calibrate: false),
    );
    final statistics = result.layers.single.rawStatistics['attitude']!;
    expect(statistics.x.count, 4);
    expect(statistics.y.count, 4);
    expect(statistics.z.count, 2);
    for (var i = 0; i < states.length; i++) {
      final error = result.records[i].rawAttitude;
      if (i == 1 || i == 5) {
        expect(error.z, closeTo(1, 1e-9));
      } else {
        expect(error.z, isNull);
      }
    }
  });

  test(
    'valid dynamic heading errors remain visible without static yaw calibration',
    () {
      final times = List.generate(14, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          for (var i = 0; i < times.length; i++)
            _point(
              times[i],
              heading: i <= 10 ? 0 : 145,
              fusionState: i <= 10 ? 1 : 5,
              gnssState: i <= 10 ? 4 : 0,
            ),
        ],
        truth: _dataset([
          for (var i = 0; i < times.length; i++)
            _truth(
              times[i],
              east: i <= 10 ? 0 : 1,
              north: 0,
              up: 0,
              heading: 120,
            ),
        ]),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.headingCount, 0);
      expect(calibration.attitudeOffset.z, isNull);
      final statistics = result.layers.single.statistics['attitude']!;
      expect(statistics.z.count, 3);
      expect(statistics.z.rmse, closeTo(25, 1e-9));
      for (final record in result.records.skip(11)) {
        expect(record.correctedAttitude.z, closeTo(25, 1e-9));
      }
    },
  );

  test(
    'last complete FIX anchors every epoch and ignores later FLOAT and INS',
    () {
      final times = List.generate(6, (i) => _start.add(Duration(seconds: i)));
      final headings = [0.0, 122.0, 124.0, 130.0, 200.0, 130.0];
      final result = evaluateAccuracy(
        points: [
          for (var i = 0; i < times.length; i++)
            _point(
              times[i],
              roll: 1,
              pitch: 2,
              heading: headings[i],
              fusionState: i == 0
                  ? 1
                  : i == 4
                  ? 5
                  : 4,
              gnssState: i == 3
                  ? 5
                  : i == 5
                  ? 0
                  : 4,
            ),
        ],
        truth: _dataset([
          for (final time in times)
            _truth(time, east: 1, north: 0, up: 0, heading: 120),
        ]),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.attitudeReferenceTime, times[2]);
      expect(calibration.attitudeCount, 1);
      expect(calibration.tiltCount, 1);
      expect(calibration.headingCount, 1);
      expect(calibration.headingBiasCount, 1);
      expect(calibration.headingBias, closeTo(4, 1e-8));
      expect(calibration.attitudeOffset.z, closeTo(4, 1e-8));
      expect(result.records.first.correctedAttitude.z, isNull);
      expect(result.records[1].correctedAttitude.z, closeTo(-2, 1e-8));
      expect(result.records[2].correctedAttitude.norm, closeTo(0, 1e-8));
      expect(result.records[3].correctedAttitude.z, closeTo(6, 1e-8));
      expect(result.records[4].correctedAttitude.z, closeTo(76, 1e-8));
      expect(result.records[5].correctedAttitude.z, closeTo(6, 1e-8));
      for (final record in result.records) {
        expect(record.correctedAttitude.x, closeTo(0, 1e-8));
        expect(record.correctedAttitude.y, closeTo(0, 1e-8));
      }
      expect(result.layers.single.statistics['attitude']!.z.count, 5);
    },
  );

  test(
    'attitude reference is chronological and independent for each source',
    () {
      final times = List.generate(5, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          _point(times[2], source: 'a.bin', heading: 124),
          _point(times[0], source: 'a.bin', heading: 122),
          _point(times[4], source: 'b.bin', heading: 129),
          _point(times[3], source: 'a.bin', heading: 130, gnssState: 5),
          _point(times[1], source: 'b.bin', heading: 127),
        ],
        truth: _dataset([
          for (final time in times)
            _truth(time, east: 1, north: 0, up: 0, heading: 120),
        ]),
      );
      final a = result.layers.firstWhere(
        (layer) => layer.sourcePath == 'a.bin',
      );
      final b = result.layers.firstWhere(
        (layer) => layer.sourcePath == 'b.bin',
      );
      expect(a.calibration.attitudeReferenceTime, times[2]);
      expect(a.calibration.headingBias, closeTo(4, 1e-9));
      expect(b.calibration.attitudeReferenceTime, times[4]);
      expect(b.calibration.headingBias, closeTo(9, 1e-9));
      expect(a.records.last.correctedAttitude.z, closeTo(6, 1e-8));
      expect(b.records.first.correctedAttitude.z, closeTo(-2, 1e-8));
      expect(b.records.last.correctedAttitude.z, closeTo(0, 1e-8));
    },
  );

  test(
    'incomplete or unmatched later FIX epochs do not replace a complete reference',
    () {
      final times = List.generate(5, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          _point(times[0], heading: 122),
          _point(times[1], heading: null),
          _point(times[2], heading: 130, roll: null),
          _point(times[3], heading: 135),
          _point(times[4], heading: 140),
        ],
        truth: _dataset([
          for (var i = 0; i <= 3; i++)
            _truth(
              times[i],
              east: 1,
              north: 0,
              up: 0,
              heading: i == 3 ? null : 120,
            ),
        ]),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.attitudeReferenceTime, times[0]);
      expect(calibration.headingBias, closeTo(2, 1e-9));
      expect(calibration.attitudeCount, 1);
      expect(result.unmatchedCount, 1);
      expect(result.records.first.correctedAttitude.norm, closeTo(0, 1e-8));
    },
  );

  test(
    'without a complete FIX the last horizontal FIX supplies only tilt offsets',
    () {
      final times = List.generate(4, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          _point(times[0], roll: 1, pitch: 2, fusionState: 1),
          _point(times[1], roll: 3, pitch: 4, fusionState: 1),
          _point(times[2], roll: 8, pitch: 9, fusionState: 1, gnssState: 5),
          _point(times[3], roll: 10, pitch: 11, heading: 145, fusionState: 5),
        ],
        truth: _dataset([
          for (final time in times)
            _truth(time, east: 1, north: 0, up: 0, heading: 120),
        ]),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.attitudeReferenceTime, times[1]);
      expect(calibration.tiltCount, 1);
      expect(calibration.attitudeCount, 0);
      expect(calibration.headingCount, 0);
      expect(calibration.headingBiasCount, 0);
      expect(calibration.headingBias, isNull);
      expect(calibration.attitudeOffset.x, closeTo(3, 1e-9));
      expect(calibration.attitudeOffset.y, closeTo(4, 1e-9));
      expect(calibration.attitudeOffset.z, isNull);
      expect(result.records.first.correctedAttitude.x, closeTo(-2, 1e-9));
      expect(result.records[1].correctedAttitude.x, closeTo(0, 1e-9));
      expect(result.records[2].correctedAttitude.x, closeTo(5, 1e-9));
      expect(result.records.last.correctedAttitude.z, closeTo(25, 1e-9));
    },
  );

  test('PPP-only or unready data cannot provide a FIX attitude anchor', () {
    final times = List.generate(3, (i) => _start.add(Duration(seconds: i)));
    for (final states in <(int?, int?)>[(5, 4), (null, 4), (4, null), (4, 5)]) {
      final result = evaluateAccuracy(
        points: [
          for (final time in times)
            _point(
              time,
              heading: 123,
              gnssState: states.$1,
              fusionState: states.$2,
            ),
        ],
        truth: _dataset([
          for (final time in times)
            _truth(time, east: 1, north: 0, up: 0, heading: 120),
        ]),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.attitudeReferenceTime, isNull);
      expect(calibration.attitudeCount, 0);
      expect(calibration.tiltCount, 0);
      expect(calibration.headingBias, isNull);
      expect(calibration.headingBiasCount, 0);
      if (states.$2 == 4 || states.$2 == 5) {
        expect(
          result.layers.single.statistics['attitude']!.z.rmse,
          closeTo(3, 1e-9),
        );
      } else {
        expect(result.layers.single.statistics['attitude']!.z.count, 0);
      }
    }
  });

  test(
    'stationary window does not restrict the final FIX attitude reference',
    () {
      final times = List.generate(3, (i) => _start.add(Duration(seconds: i)));
      final result = evaluateAccuracy(
        points: [
          _point(times[0], heading: 122),
          _point(times[1], heading: 122),
          _point(times[2], heading: 124),
        ],
        truth: _dataset([
          for (var i = 0; i < times.length; i++)
            _truth(
              times[i],
              east: i <= 1 ? 0 : 1,
              north: 0,
              up: 0,
              heading: 120,
            ),
        ]),
        options: EvaluationOptions(
          calibrationStart: times.first,
          calibrationEnd: times[1],
          stableRtkMinDurationSeconds: 0,
        ),
      );
      final calibration = result.layers.single.calibration;
      expect(calibration.intervalStart, times.first);
      expect(calibration.intervalEnd, times[1]);
      expect(calibration.positionCount, 2);
      expect(calibration.attitudeReferenceTime, times[2]);
      expect(calibration.headingBias, closeTo(4, 1e-9));
      expect(result.records.first.correctedAttitude.z, closeTo(-2, 1e-8));
    },
  );

  test('disabled calibration leaves FIX attitude errors unchanged', () {
    final times = [_start, _start.add(const Duration(seconds: 1))];
    final result = evaluateAccuracy(
      points: [_point(times[0], heading: 122), _point(times[1], heading: 124)],
      truth: _dataset([for (final time in times) _truth(time, heading: 120)]),
      options: const EvaluationOptions(calibrate: false),
    );
    final calibration = result.layers.single.calibration;
    expect(calibration.attitudeReferenceTime, isNull);
    expect(calibration.attitudeCount, 0);
    expect(calibration.headingBias, isNull);
    expect(calibration.headingBiasCount, 0);
    expect(result.records.first.correctedAttitude.z, closeTo(2, 1e-9));
    expect(result.records.last.correctedAttitude.z, closeTo(4, 1e-9));
  });

  test(
    'invalid options fail explicitly and empty data yields no fabricated metrics',
    () {
      expect(
        () => evaluateAccuracy(
          points: [],
          truth: _dataset([]),
          options: const EvaluationOptions(maxInterpolationGapSeconds: 0),
        ),
        throwsFormatException,
      );
      for (final options in [
        const EvaluationOptions(stableRtkMinDurationSeconds: -1),
        const EvaluationOptions(stableRtkMaxGapSeconds: 0),
        const EvaluationOptions(stableRtkMinDurationSeconds: double.nan),
        const EvaluationOptions(stableRtkMaxGapSeconds: double.infinity),
        const EvaluationOptions(stationarySpeedThresholdMps: -1),
        const EvaluationOptions(stationarySpeedThresholdMps: double.nan),
        const EvaluationOptions(stablePositionThresholdMeters: 0),
        const EvaluationOptions(stablePositionThresholdMeters: double.infinity),
      ]) {
        expect(
          () => evaluateAccuracy(
            points: [],
            truth: _dataset([]),
            options: options,
          ),
          throwsFormatException,
        );
      }
      final result = evaluateAccuracy(
        points: [_point(_start)],
        truth: _dataset([]),
      );
      expect(result.layers, isEmpty);
      expect(result.records, isEmpty);
      expect(result.unmatchedCount, 1);
    },
  );
}

// Independent matrix construction for the installation regression fixture.
List<List<double>> _rotation(double roll, double pitch, double heading) {
  final r = roll * math.pi / 180,
      p = pitch * math.pi / 180,
      h = heading * math.pi / 180;
  final cr = math.cos(r), sr = math.sin(r), cp = math.cos(p), sp = math.sin(p);
  final ch = math.cos(h), sh = math.sin(h);
  return [
    [ch * cp, ch * sp * sr - sh * cr, ch * sp * cr + sh * sr],
    [sh * cp, sh * sp * sr + ch * cr, sh * sp * cr - ch * sr],
    [-sp, cp * sr, cp * cr],
  ];
}

List<List<double>> _multiply(List<List<double>> a, List<List<double>> b) =>
    List.generate(
      3,
      (row) => List.generate(
        3,
        (col) => List.generate(
          3,
          (k) => a[row][k] * b[k][col],
        ).reduce((a, b) => a + b),
      ),
    );

(double, double, double) _euler(List<List<double>> matrix) => (
  math.atan2(matrix[2][1], matrix[2][2]) * 180 / math.pi,
  math.asin(-matrix[2][0]) * 180 / math.pi,
  math.atan2(matrix[1][0], matrix[0][0]) * 180 / math.pi,
);
