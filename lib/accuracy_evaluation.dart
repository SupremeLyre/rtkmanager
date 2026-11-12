import 'dart:math' as math;

import 'position_data.dart';
import 'truth_data.dart';

class EvaluationOptions {
  const EvaluationOptions({
    this.calibrate = true,
    this.maxInterpolationGapSeconds = 2,
    this.timeOffsetSeconds = 0,
    this.ggaDate,
    this.calibrationStart,
    this.calibrationEnd,
    this.stableRtkMinDurationSeconds = 10,
    this.stableRtkMaxGapSeconds = 2,
    this.stationarySpeedThresholdMps = 0.1,
    this.stablePositionThresholdMeters = 0.2,
  });

  final bool calibrate;
  final double maxInterpolationGapSeconds;
  final double timeOffsetSeconds;
  final DateTime? ggaDate;
  final DateTime? calibrationStart;
  final DateTime? calibrationEnd;
  final double stableRtkMinDurationSeconds;
  final double stableRtkMaxGapSeconds;
  final double stationarySpeedThresholdMps;
  final double stablePositionThresholdMeters;
}

class ErrorVector {
  const ErrorVector({this.x, this.y, this.z});

  final double? x;
  final double? y;
  final double? z;
  double? get horizontal =>
      x == null || y == null ? null : math.sqrt(x! * x! + y! * y!);
  double? get norm => horizontal == null || z == null
      ? null
      : math.sqrt(horizontal! * horizontal! + z! * z!);
}

class AxisStatistics {
  const AxisStatistics({required this.count, this.bias, this.rmse, this.std});

  final int count;
  final double? bias;
  final double? rmse;
  // Population standard deviation of the displayed error samples.
  final double? std;
}

class AccuracyStatistics {
  const AccuracyStatistics({
    required this.x,
    required this.y,
    required this.z,
    this.horizontalRmse,
    this.threeDimensionalRmse,
  });

  final AxisStatistics x;
  final AxisStatistics y;
  final AxisStatistics z;
  final double? horizontalRmse;
  final double? threeDimensionalRmse;
  int get count => math.max(x.count, math.max(y.count, z.count));
}

class AccuracyCalibration {
  const AccuracyCalibration({
    this.positionOffset = const ErrorVector(),
    this.velocityOffset = const ErrorVector(),
    this.attitudeOffset = const ErrorVector(),
    this.positionCount = 0,
    this.velocityCount = 0,
    this.attitudeCount = 0,
    this.tiltCount = 0,
    this.headingCount = 0,
    this.headingBias,
    this.headingBiasCount = 0,
    this.attitudeReferenceTime,
    this.stableRtkCount = 0,
    this.unavailableReason,
    this.intervalStart,
    this.intervalEnd,
  });

  final ErrorVector positionOffset;
  final ErrorVector velocityOffset;
  // ZYX Euler angles of the fitted right-side body installation rotation.
  final ErrorVector attitudeOffset;
  final int positionCount;
  final int velocityCount;
  final int attitudeCount;
  final int tiltCount;
  final int headingCount;
  final double? headingBias;
  final int headingBiasCount;
  final DateTime? attitudeReferenceTime;
  final int stableRtkCount;
  final String? unavailableReason;
  final DateTime? intervalStart;
  final DateTime? intervalEnd;
  bool get applied =>
      positionCount > 0 ||
      velocityCount > 0 ||
      attitudeCount > 0 ||
      tiltCount > 0 ||
      headingBiasCount > 0;
}

class EpochError {
  const EpochError({
    required this.point,
    required this.pointIndex,
    required this.utcTime,
    required this.truth,
    required this.rawPosition,
    required this.correctedPosition,
    required this.rawVelocity,
    required this.correctedVelocity,
    required this.rawAttitude,
    required this.correctedAttitude,
  });

  final PositionHistoryPoint point;
  final int pointIndex;
  final DateTime utcTime;
  final TruthSample truth;
  final ErrorVector rawPosition;
  final ErrorVector correctedPosition;
  final ErrorVector rawVelocity;
  final ErrorVector correctedVelocity;
  final ErrorVector rawAttitude;
  final ErrorVector correctedAttitude;

  EpochError withPoint(PositionHistoryPoint value, {int? pointIndex}) =>
      EpochError(
        point: value,
        pointIndex: pointIndex ?? this.pointIndex,
        utcTime: utcTime,
        truth: truth,
        rawPosition: rawPosition,
        correctedPosition: correctedPosition,
        rawVelocity: rawVelocity,
        correctedVelocity: correctedVelocity,
        rawAttitude: rawAttitude,
        correctedAttitude: correctedAttitude,
      );
}

class LayerAccuracyEvaluation {
  LayerAccuracyEvaluation({
    required this.layerId,
    required this.label,
    required this.sourcePath,
    required List<EpochError> records,
    required this.calibration,
    required Map<String, AccuracyStatistics> statistics,
    required Map<String, AccuracyStatistics> rawStatistics,
  }) : records = List.unmodifiable(records),
       statistics = Map.unmodifiable(statistics),
       rawStatistics = Map.unmodifiable(rawStatistics);

  final String layerId;
  final String label;
  final String? sourcePath;
  final List<EpochError> records;
  final AccuracyCalibration calibration;
  final Map<String, AccuracyStatistics> statistics;
  final Map<String, AccuracyStatistics> rawStatistics;
}

class AccuracyEvaluation {
  AccuracyEvaluation({
    required List<LayerAccuracyEvaluation> layers,
    required List<EpochError> records,
    required this.unmatchedCount,
    required Map<String, int> unmatchedReasons,
    Map<int, String> unmatchedPointReasons = const {},
  }) : layers = List.unmodifiable(layers),
       records = List.unmodifiable(records),
       unmatchedReasons = Map.unmodifiable(unmatchedReasons),
       unmatchedPointReasons = Map.unmodifiable(unmatchedPointReasons);

  final List<LayerAccuracyEvaluation> layers;
  final List<EpochError> records;
  final int unmatchedCount;
  final Map<String, int> unmatchedReasons;
  final Map<int, String> unmatchedPointReasons;

  AccuracyEvaluation withPoints(List<PositionHistoryPoint> points) {
    final remapped = <int, EpochError>{
      for (final record in records)
        record.pointIndex: record.withPoint(points[record.pointIndex]),
    };
    return AccuracyEvaluation(
      layers: [
        for (final layer in layers)
          LayerAccuracyEvaluation(
            layerId: layer.layerId,
            label: layer.label,
            sourcePath: layer.sourcePath,
            records: [
              for (final record in layer.records) remapped[record.pointIndex]!,
            ],
            calibration: layer.calibration,
            statistics: layer.statistics,
            rawStatistics: layer.rawStatistics,
          ),
      ],
      records: [for (final record in records) remapped[record.pointIndex]!],
      unmatchedCount: unmatchedCount,
      unmatchedReasons: unmatchedReasons,
      unmatchedPointReasons: unmatchedPointReasons,
    );
  }
}

AccuracyEvaluation evaluateAccuracy({
  required List<PositionHistoryPoint> points,
  required TruthDataset truth,
  EvaluationOptions options = const EvaluationOptions(),
}) {
  if (!options.maxInterpolationGapSeconds.isFinite ||
      options.maxInterpolationGapSeconds <= 0 ||
      !options.timeOffsetSeconds.isFinite) {
    throw const FormatException('时间匹配间隔必须大于零，时间偏移必须为有限数值。');
  }
  if (!options.stableRtkMinDurationSeconds.isFinite ||
      options.stableRtkMinDurationSeconds < 0 ||
      !options.stableRtkMaxGapSeconds.isFinite ||
      options.stableRtkMaxGapSeconds <= 0) {
    throw const FormatException('连续静止最短时长须大于等于零，静态解最大间隔须大于零。');
  }
  if (!options.stationarySpeedThresholdMps.isFinite ||
      options.stationarySpeedThresholdMps < 0 ||
      !options.stablePositionThresholdMeters.isFinite ||
      options.stablePositionThresholdMeters <= 0) {
    throw const FormatException('静止速度阈值须为非负数，稳定段位置变化上限须大于零。');
  }
  if (options.calibrationStart != null &&
      options.calibrationEnd != null &&
      options.calibrationStart!.isAfter(options.calibrationEnd!)) {
    throw const FormatException('标定起始时间不能晚于结束时间。');
  }
  final samples = truth.samples.toList()
    ..sort((a, b) => a.utcTime.compareTo(b.utcTime));
  final groups = <String, List<(int, PositionHistoryPoint)>>{};
  for (var i = 0; i < points.length; i++) {
    (groups[points[i].layerId] ??= []).add((i, points[i]));
  }
  final reasons = <String, int>{};
  final pointReasons = <int, String>{};
  void reject(int pointIndex, String reason) {
    pointReasons[pointIndex] = reason;
    reasons.update(reason, (n) => n + 1, ifAbsent: () => 1);
  }

  final layers = <LayerAccuracyEvaluation>[];
  final allRecords = <EpochError>[];
  for (final group in groups.entries) {
    final timed = <_TimedPoint>[];
    var dayOffset = 0;
    double? previousTod;
    for (final (index, point) in group.value) {
      final lat = point.wgs84Latitude ?? point.imuData?.lat;
      final lon = point.wgs84Longitude ?? point.imuData?.lon;
      final absolute = _absoluteTime(point);
      final tod = point.type == PointType.gga
          ? point.utcSecondsOfDay ?? _timeOfDay(point.posInfo?.utcTime)
          : null;
      if (absolute == null &&
          (tod == null || !tod.isFinite || tod < 0 || tod >= 86400)) {
        reject(index, '缺少有效的 UTC 时间');
        continue;
      }
      double? relative;
      if (absolute == null) {
        if (previousTod != null && tod! < previousTod - 43200) dayOffset++;
        previousTod = tod;
        relative = dayOffset * 86400 + tod!;
      }
      timed.add(_TimedPoint(index, point, lat, lon, absolute, relative));
    }
    final relative = timed.where((entry) => entry.time == null).toList();
    DateTime? anchor;
    if (relative.isNotEmpty && samples.isNotEmpty) {
      if (options.ggaDate != null) {
        final date = options.ggaDate!.toUtc();
        anchor = DateTime.utc(date.year, date.month, date.day);
      } else {
        anchor = _inferDay(relative, samples, options);
      }
    }
    final drafts = <_Draft>[];
    final rtkObservations = <_CalibrationObservation>[];
    for (final entry in timed) {
      if (entry.time == null && anchor == null) {
        reject(entry.index, samples.isEmpty ? '真值为空' : 'GGA 日期不明确，请指定 GGA 日期');
        continue;
      }
      final time = (entry.time ?? anchor!.add(_seconds(entry.relative!))).add(
        _seconds(options.timeOffsetSeconds),
      );
      rtkObservations.add(_CalibrationObservation(entry.point, time));
      final lat = entry.lat, lon = entry.lon;
      if (lat == null ||
          lon == null ||
          !lat.isFinite ||
          !lon.isFinite ||
          lat.abs() > 90 ||
          lon.abs() > 180) {
        reject(entry.index, '缺少有效的原始 WGS-84 经纬度');
        continue;
      }
      final matched = _interpolate(
        samples,
        time,
        options.maxInterpolationGapSeconds,
      );
      if (matched == null) {
        reject(entry.index, '超出真值时间范围或真值间隔过大');
        continue;
      }
      final point = entry.point;
      final imu = point.imuData;
      final position = _positionError(
        lat,
        lon,
        point.ellipsoidHeight ?? imu?.alt,
        matched,
      );
      final velocity = ErrorVector(
        x: _difference(point.velocityEast ?? imu?.ve, matched.velocityEast),
        y: _difference(point.velocityNorth ?? imu?.vn, matched.velocityNorth),
        z: _difference(point.velocityUp ?? imu?.vu, matched.velocityUp),
      );
      final horizontalReady = imu?.horizontalAttitudeReady == true;
      final headingReady = imu?.headingReady == true;
      final actual = horizontalReady && headingReady
          ? _Quaternion.fromOptionalEuler(imu?.roll, imu?.pitch, imu?.yaw)
          : null;
      final reference = _Quaternion.fromOptionalEuler(
        matched.roll,
        matched.pitch,
        matched.heading,
      );
      final rotation = actual == null || reference == null
          ? null
          : reference.inverse * actual;
      final attitude = ErrorVector(
        x: horizontalReady ? _angleDifference(imu?.roll, matched.roll) : null,
        y: horizontalReady ? _angleDifference(imu?.pitch, matched.pitch) : null,
        z: headingReady ? _angleDifference(imu?.yaw, matched.heading) : null,
      );
      drafts.add(
        _Draft(
          entry,
          time,
          matched,
          position,
          velocity,
          attitude,
          rotation,
          actual,
        ),
      );
    }
    if (drafts.isEmpty) continue;
    final fitting = options.calibrate
        ? _stationaryCalibrationSegment(
            rtkObservations,
            drafts,
            samples,
            options,
          )
        : <_Draft>[];
    // Fit once from this one stationary interval; reuse these constants below.
    final positionOffset = _meanVector(fitting.map((entry) => entry.position));
    final velocityOffset = _meanVector(fitting.map((entry) => entry.velocity));
    final attitudeReference = options.calibrate
        ? _lastFixedAttitude(drafts)
        : null;
    final installation = attitudeReference?.rotation;
    final tiltOffset = ErrorVector(
      x: attitudeReference?.attitude.x,
      y: attitudeReference?.attitude.y,
    );
    ErrorVector correctedAttitude(_Draft entry) {
      if (installation != null &&
          entry.actual != null &&
          entry.rotation != null) {
        final corrected = (entry.actual! * installation.inverse).euler;
        return ErrorVector(
          x: _angleDifference(corrected.x, entry.truth.roll),
          y: _angleDifference(corrected.y, entry.truth.pitch),
          z: _angleDifference(corrected.z, entry.truth.heading),
        );
      }
      // Horizontal-only startup cannot identify a yaw installation angle.
      return ErrorVector(
        x: _angleDifference(entry.attitude.x, tiltOffset.x ?? 0),
        y: _angleDifference(entry.attitude.y, tiltOffset.y ?? 0),
        z: entry.attitude.z,
      );
    }

    final calibration = AccuracyCalibration(
      positionOffset: positionOffset,
      velocityOffset: velocityOffset,
      attitudeOffset: installation?.euler ?? tiltOffset,
      positionCount: fitting
          .where((entry) => entry.position.horizontal != null)
          .length,
      velocityCount: fitting
          .where(
            (entry) =>
                entry.velocity.x != null ||
                entry.velocity.y != null ||
                entry.velocity.z != null,
          )
          .length,
      attitudeCount: installation == null ? 0 : 1,
      tiltCount: attitudeReference == null ? 0 : 1,
      headingCount: installation == null ? 0 : 1,
      headingBias: installation == null ? null : attitudeReference?.attitude.z,
      headingBiasCount: installation == null ? 0 : 1,
      attitudeReferenceTime: attitudeReference?.time,
      stableRtkCount: fitting.length,
      intervalStart: fitting.firstOrNull?.time,
      intervalEnd: fitting.lastOrNull?.time,
      unavailableReason: !options.calibrate
          ? '未启用自动标定。'
          : fitting.isNotEmpty
          ? null
          : '没有满足静止、连续稳定及时间区间要求的 ${group.value.first.$2.type == PointType.pppsol ? 'PPP' : 'RTK 固定'} 解，位置和速度保留原始误差。',
    );
    final records = <EpochError>[
      for (final entry in drafts)
        EpochError(
          point: entry.entry.point,
          pointIndex: entry.entry.index,
          utcTime: entry.time,
          truth: entry.truth,
          rawPosition: entry.position,
          correctedPosition: _subtractVector(entry.position, positionOffset),
          rawVelocity: entry.velocity,
          correctedVelocity: _subtractVector(entry.velocity, velocityOffset),
          rawAttitude: entry.attitude,
          correctedAttitude: correctedAttitude(entry),
        ),
    ]..sort((a, b) => a.utcTime.compareTo(b.utcTime));
    final point = group.value.first.$2;
    layers.add(
      LayerAccuracyEvaluation(
        layerId: group.key,
        label: point.type.name.toUpperCase(),
        sourcePath: point.sourcePath,
        records: records,
        calibration: calibration,
        statistics: {
          'position': _statistics(
            records.map((entry) => entry.correctedPosition),
          ),
          'velocity': _statistics(
            records.map((entry) => entry.correctedVelocity),
          ),
          'attitude': _statistics(
            records.map((entry) => entry.correctedAttitude),
          ),
        },
        rawStatistics: {
          'position': _statistics(records.map((entry) => entry.rawPosition)),
          'velocity': _statistics(records.map((entry) => entry.rawVelocity)),
          'attitude': _statistics(records.map((entry) => entry.rawAttitude)),
        },
      ),
    );
    allRecords.addAll(records);
  }
  allRecords.sort((a, b) => a.utcTime.compareTo(b.utcTime));
  return AccuracyEvaluation(
    layers: layers,
    records: allRecords,
    unmatchedCount: points.length - allRecords.length,
    unmatchedReasons: reasons,
    unmatchedPointReasons: pointReasons,
  );
}

class _TimedPoint {
  const _TimedPoint(
    this.index,
    this.point,
    this.lat,
    this.lon,
    this.time,
    this.relative,
  );
  final int index;
  final PositionHistoryPoint point;
  final double? lat;
  final double? lon;
  final DateTime? time;
  final double? relative;
}

class _CalibrationObservation {
  const _CalibrationObservation(this.point, this.time);
  final PositionHistoryPoint point;
  final DateTime time;
}

bool _isCalibrationFix(PositionHistoryPoint point) => switch (point.type) {
  PointType.gga => point.status == 4,
  PointType.imu => point.imuData?.gnssState == 4,
  PointType.pppsol => point.status == 4,
};

_Draft? _lastFixedAttitude(List<_Draft> drafts) {
  _Draft? full;
  _Draft? horizontal;
  for (final draft in drafts) {
    final imu = draft.entry.point.imuData;
    if (imu?.gnssState != 4 ||
        imu?.fusionState == 5 ||
        imu?.horizontalAttitudeReady != true) {
      continue;
    }
    if (draft.attitude.x == null && draft.attitude.y == null) continue;
    if (horizontal == null || !draft.time.isBefore(horizontal.time)) {
      horizontal = draft;
    }
    if (draft.rotation != null &&
        (full == null || !draft.time.isBefore(full.time))) {
      full = draft;
    }
  }
  return full ?? horizontal;
}

List<_Draft> _stationaryCalibrationSegment(
  List<_CalibrationObservation> observations,
  List<_Draft> drafts,
  List<TruthSample> truth,
  EvaluationOptions options,
) {
  observations.sort((a, b) => a.time.compareTo(b.time));
  final byPoint = {for (final draft in drafts) draft.entry.point: draft};
  final segment = <_Draft>[];
  DateTime? previous;
  TruthSample? anchor;
  TruthSample solutionPosition(_Draft draft) => TruthSample(
    utcTime: draft.time,
    latitude: draft.entry.lat!,
    longitude: draft.entry.lon!,
    height: draft.entry.point.ellipsoidHeight ?? draft.entry.point.imuData?.alt,
  );
  List<_Draft>? finishSegment() {
    final qualifies =
        segment.isNotEmpty &&
        segment.last.time.isAfter(segment.first.time) &&
        segment.last.time.difference(segment.first.time).inMicroseconds / 1e6 >=
            options.stableRtkMinDurationSeconds;
    if (qualifies) return List.of(segment);
    segment.clear();
    previous = null;
    anchor = null;
    return null;
  }

  for (var index = 0; index < observations.length;) {
    final time = observations[index].time;
    var end = index + 1;
    while (end < observations.length && observations[end].time == time) {
      end++;
    }
    final group = <_Draft>[];
    var eligible = true;
    for (var current = index; current < end; current++) {
      final observation = observations[current];
      final draft = byPoint[observation.point];
      if (!_isCalibrationFix(observation.point) ||
          draft == null ||
          (options.calibrationStart != null &&
              time.isBefore(options.calibrationStart!)) ||
          (options.calibrationEnd != null &&
              time.isAfter(options.calibrationEnd!)) ||
          !_isStationaryTruth(draft.truth, truth, options)) {
        eligible = false;
      } else {
        group.add(draft);
      }
    }
    bool exceedsSpread(TruthSample reference) {
      for (final draft in group) {
        final delta = _positionError(
          draft.entry.lat!,
          draft.entry.lon!,
          draft.entry.point.ellipsoidHeight ?? draft.entry.point.imuData?.alt,
          reference,
        );
        if ((delta.norm ?? delta.horizontal!) >
            options.stablePositionThresholdMeters) {
          return true;
        }
      }
      return false;
    }

    if (group.isNotEmpty && exceedsSpread(solutionPosition(group.first))) {
      eligible = false;
    }
    final spreadExceeded = anchor != null && exceedsSpread(anchor!);
    final gapExceeded =
        previous != null &&
        time.difference(previous!).inMicroseconds / 1e6 >
            options.stableRtkMaxGapSeconds;
    if (!eligible || gapExceeded || spreadExceeded) {
      final completed = finishSegment();
      if (completed != null) return completed;
    }
    if (eligible) {
      final first = group.first;
      anchor ??= solutionPosition(first);
      segment.addAll(group);
      previous = time;
    }
    index = end;
  }
  return finishSegment() ?? [];
}

bool _isStationaryTruth(
  TruthSample sample,
  List<TruthSample> truth,
  EvaluationOptions options,
) {
  final velocity = [
    sample.velocityEast,
    sample.velocityNorth,
    sample.velocityUp,
  ];
  if (velocity.every((value) => value != null && value.isFinite)) {
    final speed = math.sqrt(
      velocity.fold(0.0, (sum, value) => sum + value! * value),
    );
    return speed <= options.stationarySpeedThresholdMps;
  }
  var low = 0, high = truth.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (truth[middle].utcTime.isBefore(sample.utcTime)) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  final intervals = <(TruthSample, TruthSample)>[];
  if (low > 0 && low < truth.length) {
    intervals.add((truth[low - 1], truth[low]));
  }
  if (low < truth.length - 1 && truth[low].utcTime == sample.utcTime) {
    intervals.add((truth[low], truth[low + 1]));
  }
  if (intervals.isEmpty) return false;
  for (final (a, b) in intervals) {
    final seconds = b.utcTime.difference(a.utcTime).inMicroseconds / 1e6;
    if (seconds <= 0 || seconds > options.maxInterpolationGapSeconds) {
      return false;
    }
    final delta = _positionError(b.latitude, b.longitude, b.height, a);
    final speed = (delta.norm ?? delta.horizontal!) / seconds;
    if (!speed.isFinite || speed > options.stationarySpeedThresholdMps) {
      return false;
    }
  }
  return true;
}

class _Draft {
  const _Draft(
    this.entry,
    this.time,
    this.truth,
    this.position,
    this.velocity,
    this.attitude,
    this.rotation,
    this.actual,
  );
  final _TimedPoint entry;
  final DateTime time;
  final TruthSample truth;
  final ErrorVector position;
  final ErrorVector velocity;
  final ErrorVector attitude;
  final _Quaternion? rotation;
  final _Quaternion? actual;
}

Duration _seconds(double value) =>
    Duration(microseconds: (value * 1e6).round());

DateTime? _absoluteTime(PositionHistoryPoint point) {
  final imu = point.imuData;
  if (imu != null && imu.gpsWeek != null && imu.gpsTowNanos != null) {
    try {
      return gpsTimeToUtc(imu.gpsWeek!, imu.gpsTowNanos! / 1e9);
    } on FormatException {
      return null;
    }
  }
  if (point.utcDateTime != null) return point.utcDateTime!.toUtc();
  return imu == null ? null : imuUtcDateTime(imu);
}

double? _timeOfDay(String? value) =>
    value == null ? null : parseUtcSecondsOfDay(value);

DateTime? _inferDay(
  List<_TimedPoint> points,
  List<TruthSample> truth,
  EvaluationOptions options,
) {
  final start = truth.first.utcTime.toUtc();
  final end = truth.last.utcTime.toUtc();
  final span = (points.last.relative! / 86400).floor();
  var candidate = DateTime.utc(
    start.year,
    start.month,
    start.day,
  ).subtract(Duration(days: span));
  final last = DateTime.utc(end.year, end.month, end.day);
  DateTime? best;
  var bestCount = 0;
  var tied = false;
  while (!candidate.isAfter(last)) {
    var count = 0;
    for (final point in points) {
      final time = candidate.add(
        _seconds(point.relative! + options.timeOffsetSeconds),
      );
      if (_bracket(truth, time, options.maxInterpolationGapSeconds) != null) {
        count++;
      }
    }
    if (count > bestCount) {
      bestCount = count;
      best = candidate;
      tied = false;
    } else if (count != 0 && count == bestCount) {
      tied = true;
    }
    candidate = candidate.add(const Duration(days: 1));
  }
  return tied ? null : best;
}

(TruthSample, TruthSample, double)? _bracket(
  List<TruthSample> truth,
  DateTime time,
  double maxGap,
) {
  var low = 0, high = truth.length;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    if (truth[middle].utcTime.isBefore(time)) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  if (low < truth.length && truth[low].utcTime.isAtSameMomentAs(time)) {
    return (truth[low], truth[low], 0);
  }
  if (low == 0 || low == truth.length) return null;
  final a = truth[low - 1], b = truth[low];
  final gap = b.utcTime.difference(a.utcTime).inMicroseconds / 1e6;
  if (gap <= 0 || gap > maxGap) return null;
  return (a, b, time.difference(a.utcTime).inMicroseconds / (gap * 1e6));
}

TruthSample? _interpolate(
  List<TruthSample> truth,
  DateTime time,
  double maxGap,
) {
  final bracket = _bracket(truth, time, maxGap);
  if (bracket == null) return null;
  final (a, b, fraction) = bracket;
  if (identical(a, b)) return a;
  double? mix(double? x, double? y) =>
      x == null || y == null ? null : x + (y - x) * fraction;
  double? angle(double? x, double? y) => x == null || y == null
      ? null
      : _wrapAngle(x + _wrapAngle(y - x) * fraction);
  return TruthSample(
    utcTime: time,
    latitude: a.latitude + (b.latitude - a.latitude) * fraction,
    longitude: _wrapAngle(
      a.longitude + _wrapAngle(b.longitude - a.longitude) * fraction,
    ),
    height: mix(a.height, b.height),
    velocityEast: mix(a.velocityEast, b.velocityEast),
    velocityNorth: mix(a.velocityNorth, b.velocityNorth),
    velocityUp: mix(a.velocityUp, b.velocityUp),
    roll: angle(a.roll, b.roll),
    pitch: angle(a.pitch, b.pitch),
    heading: angle(a.heading, b.heading),
  );
}

// WGS-84 geodetic -> ECEF, followed by the local E/N/U basis at the truth.
// https://gssc.esa.int/navipedia/index.php/Transformations_between_ECEF_and_ENU_coordinates
ErrorVector _positionError(
  double latitude,
  double longitude,
  double? height,
  TruthSample truth,
) {
  final hasHeight = _finite(height) != null && _finite(truth.height) != null;
  final actual = _ecef(latitude, longitude, hasHeight ? height! : 0);
  final expected = _ecef(
    truth.latitude,
    truth.longitude,
    hasHeight ? truth.height! : 0,
  );
  final dx = actual.$1 - expected.$1;
  final dy = actual.$2 - expected.$2;
  final dz = actual.$3 - expected.$3;
  final lat = truth.latitude * math.pi / 180,
      lon = truth.longitude * math.pi / 180;
  final slat = math.sin(lat), clat = math.cos(lat);
  final slon = math.sin(lon), clon = math.cos(lon);
  return ErrorVector(
    x: -slon * dx + clon * dy,
    y: -slat * clon * dx - slat * slon * dy + clat * dz,
    z: hasHeight ? clat * clon * dx + clat * slon * dy + slat * dz : null,
  );
}

(double, double, double) _ecef(
  double latitude,
  double longitude,
  double height,
) {
  const a = 6378137.0;
  const e2 = 6.6943799901413165e-3;
  final lat = latitude * math.pi / 180, lon = longitude * math.pi / 180;
  final sinLat = math.sin(lat), cosLat = math.cos(lat);
  final radius = a / math.sqrt(1 - e2 * sinLat * sinLat);
  return (
    (radius + height) * cosLat * math.cos(lon),
    (radius + height) * cosLat * math.sin(lon),
    (radius * (1 - e2) + height) * sinLat,
  );
}

double? _finite(double? value) => value?.isFinite == true ? value : null;
double? _difference(double? a, double? b) =>
    _finite(a) == null || _finite(b) == null ? null : a! - b!;
double _wrapAngle(double angle) => (angle + 180) % 360 - 180;
double? _angleDifference(double? a, double? b) {
  final value = _difference(a, b);
  return value == null ? null : _wrapAngle(value);
}

ErrorVector _subtractVector(ErrorVector a, ErrorVector b) => ErrorVector(
  x: a.x == null ? null : a.x! - (b.x ?? 0),
  y: a.y == null ? null : a.y! - (b.y ?? 0),
  z: a.z == null ? null : a.z! - (b.z ?? 0),
);

ErrorVector _meanVector(Iterable<ErrorVector> vectors) {
  final x = _AxisAccumulator(), y = _AxisAccumulator(), z = _AxisAccumulator();
  for (final vector in vectors) {
    x.add(vector.x);
    y.add(vector.y);
    z.add(vector.z);
  }
  return ErrorVector(x: x.result.bias, y: y.result.bias, z: z.result.bias);
}

AccuracyStatistics _statistics(Iterable<ErrorVector> vectors) {
  final x = _AxisAccumulator(), y = _AxisAccumulator(), z = _AxisAccumulator();
  var horizontalSquares = 0.0, fullSquares = 0.0;
  var horizontalCount = 0, fullCount = 0;
  for (final vector in vectors) {
    x.add(vector.x);
    y.add(vector.y);
    z.add(vector.z);
    if (vector.horizontal != null) {
      horizontalSquares += vector.x! * vector.x! + vector.y! * vector.y!;
      horizontalCount++;
      if (vector.z != null) {
        fullSquares +=
            vector.x! * vector.x! +
            vector.y! * vector.y! +
            vector.z! * vector.z!;
        fullCount++;
      }
    }
  }
  return AccuracyStatistics(
    x: x.result,
    y: y.result,
    z: z.result,
    horizontalRmse: horizontalCount == 0
        ? null
        : math.sqrt(horizontalSquares / horizontalCount),
    threeDimensionalRmse: fullCount == 0
        ? null
        : math.sqrt(fullSquares / fullCount),
  );
}

class _AxisAccumulator {
  var count = 0;
  var mean = 0.0, m2 = 0.0, squares = 0.0;
  void add(double? value) {
    if (_finite(value) == null) return;
    count++;
    final delta = value! - mean;
    mean += delta / count;
    m2 += delta * (value - mean);
    squares += value * value;
  }

  AxisStatistics get result => AxisStatistics(
    count: count,
    bias: count == 0 ? null : mean,
    rmse: count == 0 ? null : math.sqrt(squares / count),
    std: count == 0 ? null : math.sqrt(math.max(0, m2 / count)),
  );
}

// Hamilton quaternion, active ZYX rotation Rz(heading) Ry(pitch) Rx(roll).
// Installation B is fitted from inv(Rtruth) Rsolution; correction is Rsolution inv(B).
class _Quaternion {
  const _Quaternion(this.w, this.x, this.y, this.z);
  final double w, x, y, z;
  _Quaternion get inverse => _Quaternion(w, -x, -y, -z);
  _Quaternion operator *(_Quaternion b) => _Quaternion(
    w * b.w - x * b.x - y * b.y - z * b.z,
    w * b.x + x * b.w + y * b.z - z * b.y,
    w * b.y - x * b.z + y * b.w + z * b.x,
    w * b.z + x * b.y - y * b.x + z * b.w,
  );

  static _Quaternion? fromOptionalEuler(
    double? roll,
    double? pitch,
    double? yaw,
  ) {
    if (_finite(roll) == null ||
        _finite(pitch) == null ||
        _finite(yaw) == null) {
      return null;
    }
    final r = roll! * math.pi / 360,
        p = pitch! * math.pi / 360,
        h = yaw! * math.pi / 360;
    final cr = math.cos(r),
        sr = math.sin(r),
        cp = math.cos(p),
        sp = math.sin(p);
    final ch = math.cos(h), sh = math.sin(h);
    return _Quaternion(
      cr * cp * ch + sr * sp * sh,
      sr * cp * ch - cr * sp * sh,
      cr * sp * ch + sr * cp * sh,
      cr * cp * sh - sr * sp * ch,
    );
  }

  ErrorVector get euler => ErrorVector(
    x: _wrapAngle(
      math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * 180 / math.pi,
    ),
    y: math.asin((2 * (w * y - z * x)).clamp(-1.0, 1.0)) * 180 / math.pi,
    z: _wrapAngle(
      math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)) * 180 / math.pi,
    ),
  );
}
