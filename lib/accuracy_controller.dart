import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'accuracy_evaluation.dart';
import 'position_data.dart';
import 'truth_data.dart';

typedef _EvaluationJob = ({
  List<PositionHistoryPoint> points,
  TruthDataset truth,
  EvaluationOptions options,
});

AccuracyEvaluation _runEvaluation(_EvaluationJob job) => evaluateAccuracy(
  points: job.points,
  truth: job.truth,
  options: job.options,
);

class AccuracyController extends ChangeNotifier {
  List<PositionHistoryPoint> _points = const [];
  TruthDataset? _truth;
  AccuracyEvaluation? _evaluation;
  PositionHistoryPoint? _selectedPoint;
  final Map<PositionHistoryPoint, EpochError> _errors = HashMap.identity();
  bool _busy = false;
  String? _error;
  int _revision = 0;
  bool _disposed = false;
  EvaluationOptions _options = const EvaluationOptions();
  int _locateRevision = 0;

  List<PositionHistoryPoint> get points => _points;
  TruthDataset? get truth => _truth;
  AccuracyEvaluation? get evaluation => _evaluation;
  PositionHistoryPoint? get selectedPoint => _selectedPoint;
  EpochError? get selectedError => _errors[_selectedPoint];
  bool get busy => _busy;
  String? get error => _error;
  EvaluationOptions get options => _options;
  int get locateRevision => _locateRevision;

  void locateSelectedPoint() {
    if (_selectedPoint == null) return;
    _locateRevision++;
    notifyListeners();
  }

  void setPoints(List<PositionHistoryPoint> points) {
    if (listEquals(_points, points)) return;
    _points = List.unmodifiable(points);
    _invalidate();
    if (!_points.contains(_selectedPoint)) _selectedPoint = null;
    notifyListeners();
  }

  void removeSource(String sourcePath) {
    final removesTruth = _truth?.sourcePath == sourcePath;
    if (!removesTruth &&
        !_points.any((point) => point.sourcePath == sourcePath)) {
      return;
    }
    final remaining = <PositionHistoryPoint>[];
    final newIndices = <int, int>{};
    for (var index = 0; index < _points.length; index++) {
      final point = _points[index];
      if (point.sourcePath == sourcePath) continue;
      newIndices[index] = remaining.length;
      remaining.add(point);
    }
    _points = List.unmodifiable(remaining);
    if (_selectedPoint?.sourcePath == sourcePath) _selectedPoint = null;
    if (removesTruth) {
      _truth = null;
      _invalidate();
    } else {
      _revision++;
      _error = null;
      final evaluation = _evaluation;
      if (evaluation != null) {
        final records = <int, EpochError>{
          for (final record in evaluation.records)
            if (newIndices.containsKey(record.pointIndex))
              record.pointIndex: record.withPoint(
                _points[newIndices[record.pointIndex]!],
                pointIndex: newIndices[record.pointIndex]!,
              ),
        };
        final pointReasons = <int, String>{
          for (final entry in evaluation.unmatchedPointReasons.entries)
            if (newIndices.containsKey(entry.key))
              newIndices[entry.key]!: entry.value,
        };
        final reasons = <String, int>{};
        for (final reason in pointReasons.values) {
          reasons.update(reason, (count) => count + 1, ifAbsent: () => 1);
        }
        _evaluation = AccuracyEvaluation(
          layers: [
            for (final layer in evaluation.layers)
              if (layer.sourcePath != sourcePath)
                LayerAccuracyEvaluation(
                  layerId: layer.layerId,
                  label: layer.label,
                  sourcePath: layer.sourcePath,
                  records: [
                    for (final record in layer.records)
                      records[record.pointIndex]!,
                  ],
                  calibration: layer.calibration,
                  statistics: layer.statistics,
                  rawStatistics: layer.rawStatistics,
                ),
          ],
          records: [
            for (final record in evaluation.records)
              if (records.containsKey(record.pointIndex))
                records[record.pointIndex]!,
          ],
          unmatchedCount: _points.length - records.length,
          unmatchedReasons: reasons,
          unmatchedPointReasons: pointReasons,
        );
      }
      _errors
        ..clear()
        ..addEntries(
          (_evaluation?.records ?? const <EpochError>[]).map(
            (record) => MapEntry(record.point, record),
          ),
        );
    }
    notifyListeners();
  }

  void _invalidate() {
    _revision++;
    _evaluation = null;
    _errors.clear();
    _error = null;
    _options = const EvaluationOptions();
  }

  void selectPoint(PositionHistoryPoint? point) {
    if (identical(point, _selectedPoint)) return;
    _selectedPoint = point;
    notifyListeners();
  }

  void setTruthDataset(TruthDataset truth) {
    _truth = truth;
    _invalidate();
    notifyListeners();
  }

  void clearTruth() {
    _truth = null;
    _invalidate();
    notifyListeners();
  }

  void reportError(String message) {
    _error = message;
    notifyListeners();
  }

  Future<void> importTruth(
    String path, {
    TruthColumnMapping? mapping,
    int gpsUtcOffsetSeconds = 18,
  }) async {
    if (_busy) return;
    _busy = true;
    _error = null;
    final revision = ++_revision;
    notifyListeners();
    try {
      final truth = await readTruthFile(
        path,
        mapping: mapping,
        gpsUtcOffsetSeconds: gpsUtcOffsetSeconds,
      );
      if (_disposed || revision != _revision) return;
      _truth = truth;
      _evaluation = null;
      _errors.clear();
    } catch (error) {
      if (!_disposed && revision == _revision) _error = '真值导入失败：$error';
    } finally {
      if (!_disposed) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> evaluate({
    EvaluationOptions options = const EvaluationOptions(),
  }) async {
    if (_busy) return;
    if (_truth == null || _points.isEmpty) {
      reportError('请先导入定位结果和真值文件。');
      return;
    }
    _busy = true;
    _error = null;
    final revision = _revision;
    notifyListeners();
    try {
      final result = await compute(_runEvaluation, (
        points: _points,
        truth: _truth!,
        options: options,
      ));
      if (_disposed || revision != _revision) return;
      final rebound = result.withPoints(_points);
      _evaluation = rebound;
      _options = options;
      _errors
        ..clear()
        ..addEntries(rebound.records.map((item) => MapEntry(item.point, item)));
      if (_errors[_selectedPoint] == null && rebound.records.isNotEmpty) {
        _selectedPoint = rebound.records.first.point;
      }
    } catch (error) {
      if (!_disposed && revision == _revision) _error = '精度评定失败：$error';
    } finally {
      if (!_disposed) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
