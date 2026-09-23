import 'dart:collection';

import 'imu_data_parser.dart';

enum ImuVector { acceleration, gyroscope, magnetic }

class ImuPoint {
  const ImuPoint(this.timeUs, this.values);
  final int timeUs;
  final List<double> values;
}

/// Bounded display history. Raw files and sensor acquisition never depend on it.
class ImuHistory {
  ImuHistory({this.maxPoints = 12000, this.retentionSeconds = 30});
  final int maxPoints;
  final int retentionSeconds;
  final _series = {
    for (final kind in ImuVector.values) kind: ListQueue<ImuPoint>(),
  };
  int count = 0;
  int? latestTimeUs;
  String timeBasis = '接收时间';
  DateTime? lastArrival;
  final Map<ImuVector, DateTime> _arrivals = {};

  List<ImuPoint> points(ImuVector kind, int seconds) {
    final end = latestTimeUs;
    if (end == null) return [];
    return _series[kind]!
        .where((p) => p.timeUs >= end - seconds * 1000000)
        .toList(growable: false);
  }

  double rate(ImuVector kind, DateTime now) {
    final list = _series[kind]!;
    final arrival = _arrivals[kind];
    if (arrival == null ||
        now.difference(arrival).inMilliseconds > 2000 ||
        list.length < 2) {
      return 0;
    }
    final end = list.last.timeUs;
    final recent = list.where((p) => p.timeUs >= end - 2000000).toList();
    if (recent.length < 2 || recent.last.timeUs <= recent.first.timeUs) {
      return 0;
    }
    return (recent.length - 1) *
        1000000 /
        (recent.last.timeUs - recent.first.timeUs);
  }

  void add(ImuData data, {required int arrivalUs, required DateTime now}) {
    final vectors = {
      ImuVector.acceleration: [data.ax, data.ay, data.az],
      ImuVector.gyroscope: [data.wx, data.wy, data.wz],
      ImuVector.magnetic: [data.mx, data.my, data.mz],
    };
    if (!vectors.values.any((v) => v.every((n) => n != null && n.isFinite))) {
      return;
    }
    var time = arrivalUs;
    var basis = '接收时间';
    if (data.gpsWeek != null && data.gpsTowNanos != null) {
      time = data.gpsWeek! * 604800000000 + data.gpsTowNanos! ~/ 1000;
      basis = 'GPS 采样时间';
    } else if ([
      data.utcYear,
      data.utcMonth,
      data.utcDay,
      data.utcHour,
      data.utcMin,
      data.utcSec,
    ].every((v) => v != null)) {
      time = DateTime.utc(
        data.utcYear!,
        data.utcMonth!,
        data.utcDay!,
        data.utcHour!,
        data.utcMin!,
        data.utcSec!,
        data.utcDateTimeMsec,
        data.utcDateTimeUsec,
      ).microsecondsSinceEpoch;
      basis = 'UTC 采样时间';
    }
    // Do not join different clocks or a restarted device into one curve.
    if (latestTimeUs != null &&
        (basis != timeBasis || time < latestTimeUs! - 1000000)) {
      clear();
    }
    timeBasis = basis;
    latestTimeUs = latestTimeUs == null || time > latestTimeUs!
        ? time
        : latestTimeUs;
    count++;
    lastArrival = now;
    for (final entry in vectors.entries) {
      if (entry.value.any((v) => v == null || !v.isFinite)) continue;
      final list = _series[entry.key]!;
      // A batched magnetic callback may arrive after newer IMU frames. Keep
      // each series chronological without discarding data from another sensor.
      if (list.isNotEmpty && time < list.last.timeUs) continue;
      list.addLast(ImuPoint(time, entry.value.cast<double>()));
      _arrivals[entry.key] = now;
    }
    for (final list in _series.values) {
      while (list.isNotEmpty &&
          (list.length > maxPoints ||
              list.first.timeUs < latestTimeUs! - retentionSeconds * 1000000)) {
        list.removeFirst();
      }
    }
  }

  void clear() {
    for (final list in _series.values) {
      list.clear();
    }
    _arrivals.clear();
    count = 0;
    latestTimeUs = null;
    lastArrival = null;
  }
}
