import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'imu_data_parser.dart';
import 'position_data.dart';

enum ImuFileVector { acceleration, gyroscope, magnetic, attitude, velocity }

/// One display sample, preserving unavailable axes as gaps rather than zeroes.
class ImuFilePoint {
  ImuFilePoint({
    required this.time,
    required List<double?> values,
    this.breakBefore = false,
    List<bool> axisBreaks = const [false, false, false],
  }) : values = List<double?>.unmodifiable(values),
       axisBreaks = List<bool>.unmodifiable(axisBreaks);

  final double time;
  final List<double?> values;
  final bool breakBefore;

  /// Missing/invalid intervals skipped by decimation, independently per axis.
  final List<bool> axisBreaks;
}

/// An immutable, bounded view of an entire source file, independent of live IMU.
class ImuFileDataset {
  ImuFileDataset({
    required this.sourcePath,
    String? name,
    required this.frameCount,
    required this.timeBasis,
    required this.xAxisLabel,
    required this.start,
    required this.end,
    required Map<ImuFileVector, List<ImuFilePoint>> series,
  }) : _name = name,
       series = Map<ImuFileVector, List<ImuFilePoint>>.unmodifiable({
         for (final kind in ImuFileVector.values)
           kind: List<ImuFilePoint>.unmodifiable(series[kind] ?? const []),
       });

  final String sourcePath;
  final String? _name;
  String get name => _name ?? sourcePath.split(RegExp(r'[/\\]')).last;
  final int frameCount;
  final String timeBasis;
  final String xAxisLabel;
  final double start;
  final double end;
  final Map<ImuFileVector, List<ImuFilePoint>> series;

  bool get isEmpty => !series.values.any(
    (points) => points.any(
      (point) => point.values.any((value) => value != null && value.isFinite),
    ),
  );
}

/// Consumes every parsed frame before any position or whole-second filtering.
///
/// Decimation retains the endpoints and axis extrema across the entire file.
/// A common GPS or UTC clock supplies elapsed seconds; incomplete clocks use
/// original frame numbers so no sampling rate or missing timestamp is invented.
class ImuFileBuilder {
  ImuFileBuilder(this.sourcePath, {this.maxPoints = 12000}) {
    if (maxPoints < 2) {
      throw ArgumentError.value(maxPoints, 'maxPoints', 'Must be at least 2');
    }
  }

  final String sourcePath;
  final int maxPoints;
  final _series = {
    for (final kind in ImuFileVector.values) kind: _FileSeries(),
  };
  int _frameCount = 0;
  int? _firstFrame;
  int? _lastFrame;
  _GpsStamp? _gpsOrigin;
  int? _utcOrigin;
  bool _allGps = true;
  bool _allUtc = true;
  double _gpsStart = 0;
  double _gpsEnd = 0;
  double _utcStart = 0;
  double _utcEnd = 0;

  void add(ImuData data) {
    final frame = _frameCount++;
    final gps = _GpsStamp.fromData(data);
    // Firmware emits UTC in year 2000 until its clock is synchronized.
    final unsynchronizedUtc = data.utcYear != null && data.utcYear! <= 2000;
    if (gps == null && unsynchronizedUtc) return;

    final hasStatus = data.startupStage != null || data.fusionState != null;
    final horizontal = !hasStatus || data.horizontalAttitudeReady;
    final heading = !hasStatus || data.headingReady;
    final vectors = <ImuFileVector, List<double?>>{
      ImuFileVector.acceleration: [data.ax, data.ay, data.az],
      ImuFileVector.gyroscope: [data.wx, data.wy, data.wz],
      ImuFileVector.magnetic: [data.mx, data.my, data.mz],
      ImuFileVector.attitude: [data.roll, data.pitch, data.yaw],
      ImuFileVector.velocity: [data.ve, data.vn, data.vu],
    };
    if (!vectors.values.any((axes) => axes.any((value) => value != null))) {
      return;
    }

    final utc = unsynchronizedUtc
        ? null
        : imuUtcDateTime(data)?.microsecondsSinceEpoch;
    _firstFrame ??= frame;
    _lastFrame = frame;
    _allGps = _allGps && gps != null;
    _allUtc = _allUtc && utc != null;
    if (gps != null) {
      _gpsOrigin ??= gps;
      final elapsed = gps.secondsSince(_gpsOrigin!);
      _gpsStart = math.min(_gpsStart, elapsed);
      _gpsEnd = math.max(_gpsEnd, elapsed);
    }
    if (utc != null) {
      _utcOrigin ??= utc;
      final elapsed = (utc - _utcOrigin!) / Duration.microsecondsPerSecond;
      _utcStart = math.min(_utcStart, elapsed);
      _utcEnd = math.max(_utcEnd, elapsed);
    }

    for (final entry in vectors.entries) {
      if (!entry.value.any((value) => value != null)) continue;
      final values = entry.value.map(_finite).toList(growable: false);
      if (entry.key == ImuFileVector.attitude) {
        if (!horizontal) {
          values[0] = null;
          values[1] = null;
        }
        if (!heading) {
          values[2] = null;
        } else if (values[2] != null) {
          values[2] = _wrapHeadingDegrees(values[2]!);
        }
      } else if (entry.key == ImuFileVector.velocity && !heading) {
        values.fillRange(0, 3, null);
      }
      _series[entry.key]!.add(
        _FileSample(frame: frame, values: values, gps: gps, utc: utc),
        maxPoints,
        yaw: entry.key == ImuFileVector.attitude,
      );
    }
  }

  ImuFileDataset build() {
    final useGps = _firstFrame != null && _allGps && _gpsOrigin != null;
    final useUtc =
        !useGps && _firstFrame != null && _allUtc && _utcOrigin != null;
    return ImuFileDataset(
      sourcePath: sourcePath,
      frameCount: _frameCount,
      timeBasis: useGps
          ? 'GPS 时间'
          : useUtc
          ? 'UTC 时间'
          : '帧序号（时间缺失或时钟不一致）',
      xAxisLabel: useGps || useUtc ? '经过时间 (s)' : '帧序号',
      start: useGps
          ? _gpsStart
          : useUtc
          ? _utcStart
          : (_firstFrame ?? 0).toDouble(),
      end: useGps
          ? _gpsEnd
          : useUtc
          ? _utcEnd
          : (_lastFrame ?? 0).toDouble(),
      series: {
        for (final entry in _series.entries)
          entry.key: [
            for (final sample in _decimate(entry.value.points, maxPoints))
              ImuFilePoint(
                time: useGps
                    ? sample.gps!.secondsSince(_gpsOrigin!)
                    : useUtc
                    ? (sample.utc! - _utcOrigin!) /
                          Duration.microsecondsPerSecond
                    : sample.frame.toDouble(),
                values: sample.values,
                breakBefore: useGps
                    ? sample.gpsBreak
                    : useUtc
                    ? sample.utcBreak
                    : sample.gpsBreak || sample.utcBreak,
                axisBreaks: [
                  sample.axisBreaks[0],
                  sample.axisBreaks[1],
                  sample.axisBreaks[2] || sample.yawBreak,
                ],
              ),
          ],
      },
    );
  }
}

double? _finite(double? value) =>
    value != null && value.isFinite ? value : null;

/// Signed display heading, preserving the sign of exact ±180° boundaries.
double _wrapHeadingDegrees(double value) {
  if (value >= -180 && value <= 180) return value;
  final wrapped = value % 360;
  if (wrapped > 180) return wrapped - 360;
  return wrapped == 180 && value < 0 ? -180 : wrapped;
}

class _GpsStamp {
  const _GpsStamp(this.week, this.nanos);

  final int week;
  final int nanos;

  static _GpsStamp? fromData(ImuData data) {
    final week = data.gpsWeek;
    final nanos = data.gpsTowNanos;
    if (week == null ||
        week < 0 ||
        week > 65535 ||
        nanos == null ||
        nanos < 0 ||
        nanos >= 604800000000000) {
      return null;
    }
    return _GpsStamp(week, nanos);
  }

  double secondsSince(_GpsStamp other) {
    final weeks = week - other.week;
    // Subtract before converting to floating point, preserving submicrosecond
    // precision at week rollover. Very distant dates need no nanos precision.
    if (weeks.abs() < 10000) {
      return (weeks * 604800000000000 + nanos - other.nanos) / 1000000000;
    }
    return weeks * 604800.0 + (nanos - other.nanos) / 1000000000;
  }
}

class _FileSample {
  _FileSample({
    required this.frame,
    required this.values,
    required this.gps,
    required this.utc,
    this.gpsBreak = false,
    this.utcBreak = false,
    this.yawBreak = false,
    this.axisBreaks = const [false, false, false],
  });

  final int frame;
  final List<double?> values;
  final _GpsStamp? gps;
  final int? utc;
  final bool gpsBreak;
  final bool utcBreak;
  final bool yawBreak;
  final List<bool> axisBreaks;

  _FileSample withBreaks({
    bool gps = false,
    bool utc = false,
    bool yaw = false,
    List<bool>? axes,
  }) => _FileSample(
    frame: frame,
    values: values,
    gps: this.gps,
    utc: this.utc,
    gpsBreak: gpsBreak || gps,
    utcBreak: utcBreak || utc,
    yawBreak: yawBreak || yaw,
    axisBreaks: [
      for (var axis = 0; axis < 3; axis++)
        axisBreaks[axis] || (axes?[axis] ?? false),
    ],
  );
}

class _FileSeries {
  List<_FileSample> points = [];
  _FileSample? _previous;
  double? _gpsStep;
  double? _utcStep;

  void add(_FileSample sample, int maxPoints, {required bool yaw}) {
    final previous = _previous;
    final gpsDelta = previous?.gps != null && sample.gps != null
        ? sample.gps!.secondsSince(previous!.gps!)
        : null;
    final utcDelta = previous?.utc != null && sample.utc != null
        ? (sample.utc! - previous!.utc!) / Duration.microsecondsPerSecond
        : null;
    final gpsBreak = _isDiscontinuity(gpsDelta, _gpsStep);
    final utcBreak = _isDiscontinuity(utcDelta, _utcStep);
    if (gpsDelta != null && gpsDelta > 0 && !gpsBreak) _gpsStep = gpsDelta;
    if (utcDelta != null && utcDelta > 0 && !utcBreak) _utcStep = utcDelta;
    final lastYaw = yaw ? previous?.values[2] : null;
    final nextYaw = yaw ? sample.values[2] : null;
    points.add(
      sample.withBreaks(
        gps: gpsBreak,
        utc: utcBreak,
        yaw:
            lastYaw != null &&
            nextYaw != null &&
            (nextYaw - lastYaw).abs() > 180,
        axes: [
          for (var axis = 0; axis < 3; axis++)
            previous != null &&
                previous.values[axis] == null &&
                sample.values[axis] != null,
        ],
      ),
    );
    _previous = sample;
    if (points.length > maxPoints * 2) points = _decimate(points, maxPoints);
  }
}

bool _isDiscontinuity(double? delta, double? step) =>
    delta != null && (delta < 0 || delta > math.max(1, (step ?? 0) * 10));

/// Keep an envelope in consecutive buckets, including null gaps and endpoints.
List<_FileSample> _decimate(List<_FileSample> points, int limit) {
  if (points.length <= limit) return List<_FileSample>.of(points);
  final selected = <int>{0, points.length - 1};
  if (limit < 13) {
    for (var index = 1; index < limit - 1; index++) {
      selected.add((index * (points.length - 1) / (limit - 1)).round());
    }
  } else {
    final bucketCount = (limit - 2) ~/ 11;
    final firstFrame = points.first.frame;
    final frameSpan = points.last.frame - firstFrame + 1;
    var first = 1;
    for (var bucket = 0; bucket < bucketCount; bucket++) {
      var end = first;
      final frameEnd = firstFrame + (bucket + 1) * frameSpan / bucketCount;
      while (end < points.length - 1 && points[end].frame < frameEnd) {
        end++;
      }
      if (end == first) continue;
      selected.add(first);
      selected.add(end - 1);
      for (var axis = 0; axis < 3; axis++) {
        int? minIndex;
        int? maxIndex;
        int? nullIndex;
        for (var index = first; index < end; index++) {
          final value = points[index].values[axis];
          if (value == null) {
            nullIndex ??= index;
          } else {
            if (minIndex == null || value < points[minIndex].values[axis]!) {
              minIndex = index;
            }
            if (maxIndex == null || value > points[maxIndex].values[axis]!) {
              maxIndex = index;
            }
          }
        }
        if (minIndex != null) selected.add(minIndex);
        if (maxIndex != null) selected.add(maxIndex);
        if (nullIndex != null) selected.add(nullIndex);
      }
      first = end;
    }
  }
  final ordered = selected.toList()..sort();
  final result = <_FileSample>[];
  var cursor = 0;
  for (final index in ordered) {
    var gpsBreak = false;
    var utcBreak = false;
    var yawBreak = false;
    final axisBreaks = [false, false, false];
    for (; cursor <= index; cursor++) {
      gpsBreak = gpsBreak || points[cursor].gpsBreak;
      utcBreak = utcBreak || points[cursor].utcBreak;
      yawBreak = yawBreak || points[cursor].yawBreak;
      for (var axis = 0; axis < 3; axis++) {
        axisBreaks[axis] = axisBreaks[axis] || points[cursor].axisBreaks[axis];
      }
    }
    result.add(
      points[index].withBreaks(
        gps: gpsBreak,
        utc: utcBreak,
        yaw: yawBreak,
        axes: axisBreaks,
      ),
    );
  }
  return result;
}

/// Streams and decodes off the UI isolate without publishing live sensor data.
Future<ImuFileDataset> loadImuFile(String path) =>
    Isolate.run(() => _loadImuFileInIsolate(path));

Future<ImuFileDataset> _loadImuFileInIsolate(String path) async {
  final builder = ImuFileBuilder(path);
  final parser = ImuDataParser();
  await for (final chunk in File(path).openRead()) {
    // Small parser batches avoid repeatedly shifting a whole file-stream chunk.
    for (var offset = 0; offset < chunk.length; offset += 4096) {
      parser.parseData(
        chunk.sublist(offset, math.min(offset + 4096, chunk.length)),
        builder.add,
        broadcast: false,
      );
    }
  }
  return builder.build();
}

/// Shared file selection for position imports and the offline visualization.
class ImuFileController extends ChangeNotifier {
  ImuFileController({Future<ImuFileDataset> Function(String)? loader})
    : _loader = loader ?? loadImuFile;

  final Future<ImuFileDataset> Function(String) _loader;
  final List<ImuFileDataset> _datasets = [];
  final Map<String, Object> _pending = {};
  String? _selectedPath;
  bool _disposed = false;

  List<ImuFileDataset> get datasets => List.unmodifiable(_datasets);
  String? get selectedPath => _selectedPath;
  ImuFileDataset? get selected {
    for (final dataset in _datasets) {
      if (dataset.sourcePath == _selectedPath) return dataset;
    }
    return null;
  }

  void add(ImuFileDataset dataset) {
    if (_disposed) return;
    _pending.remove(dataset.sourcePath);
    final index = _datasets.indexWhere(
      (item) => item.sourcePath == dataset.sourcePath,
    );
    if (index < 0) {
      _datasets.add(dataset);
    } else {
      _datasets[index] = dataset;
    }
    _selectedPath = dataset.sourcePath;
    notifyListeners();
  }

  void select(String? path) {
    if (_disposed || path == _selectedPath) return;
    if (path != null && !_datasets.any((item) => item.sourcePath == path)) {
      return;
    }
    _selectedPath = path;
    notifyListeners();
  }

  void remove(String path) {
    if (_disposed) return;
    _pending.remove(path);
    final count = _datasets.length;
    _datasets.removeWhere((item) => item.sourcePath == path);
    if (_selectedPath == path) {
      _selectedPath = _datasets.isEmpty ? null : _datasets.last.sourcePath;
    }
    if (count != _datasets.length) notifyListeners();
  }

  void clear() {
    if (_disposed) return;
    _pending.clear();
    if (_datasets.isEmpty && _selectedPath == null) return;
    _datasets.clear();
    _selectedPath = null;
    notifyListeners();
  }

  /// Clearing, removing, or disposing during import cancels its state update.
  Future<ImuFileDataset> importFile(String path) async {
    final token = Object();
    if (!_disposed) _pending[path] = token;
    try {
      final dataset = await _loader(path);
      if (!_disposed && identical(_pending[path], token)) {
        _pending.remove(path);
        if (!dataset.isEmpty) add(dataset);
      }
      return dataset;
    } finally {
      if (identical(_pending[path], token)) _pending.remove(path);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pending.clear();
    super.dispose();
  }
}
