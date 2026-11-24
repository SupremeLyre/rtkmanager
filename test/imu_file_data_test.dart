import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/imu_file_data.dart';

void main() {
  test(
    'wraps displayed headings to signed degrees without changing raw data',
    () {
      final cases = <(double, double)>[
        (-1080, 0),
        (-900, -180),
        (-720, 0),
        (-540, -180),
        (-360, 0),
        (-270, 90),
        (-181, 179),
        (-180, -180),
        (-179, -179),
        (-1e-12, -1e-12),
        (0, 0),
        (179, 179),
        (180, 180),
        (181, -179),
        (270, -90),
        (359, -1),
        (360, 0),
        (540, 180),
        (720, 0),
        (900, 180),
        (1080, 0),
      ];
      final builder = ImuFileBuilder('heading.bin');
      final raw = <ImuData>[];
      for (var index = 0; index < cases.length; index++) {
        final frame = _gps(index * 10000000)
          ..roll = 270
          ..pitch = -270
          ..yaw = cases[index].$1;
        raw.add(frame);
        builder.add(frame);
      }
      final points = builder.build().series[ImuFileVector.attitude]!;
      expect(
        points.map((point) => point.values[2]),
        cases.map((entry) => entry.$2),
      );
      expect(points.every((point) => point.values[0] == 270), isTrue);
      expect(points.every((point) => point.values[1] == -270), isTrue);
      expect(raw.map((frame) => frame.yaw), cases.map((entry) => entry.$1));
    },
  );

  test('heading gaps follow the signed boundary rather than zero degrees', () {
    final builder = ImuFileBuilder('heading-crossings.bin');
    final headings = [
      358.0,
      359.0,
      0.0,
      1.0,
      179.0,
      181.0,
      182.0,
      -179.0,
      -181.0,
    ];
    for (var index = 0; index < headings.length; index++) {
      builder.add(
        _gps(index * 10000000)
          ..roll = 1
          ..pitch = 2
          ..yaw = headings[index],
      );
    }
    final points = builder.build().series[ImuFileVector.attitude]!;
    expect(points.map((point) => point.values[2]), [
      -2,
      -1,
      0,
      1,
      179,
      -179,
      -178,
      -179,
      179,
    ]);
    expect(points.map((point) => point.axisBreaks[2]), [
      false,
      false,
      false,
      false,
      false,
      true,
      false,
      false,
      true,
    ]);
    expect(
      points.every(
        (point) =>
            !point.axisBreaks[0] && !point.axisBreaks[1] && !point.breakBefore,
      ),
      isTrue,
    );
  });

  test('retains the entire duration and extremes within a bounded display', () {
    final builder = ImuFileBuilder('C:\\logs\\long.bin', maxPoints: 80);
    for (var index = 0; index <= 6000; index++) {
      builder.add(
        _gps(index * 10000000)
          ..ax = index == 15
              ? -1000
              : index == 5985
              ? 2000
              : 1
          ..ay = 0
          ..az = 1,
      );
    }
    final data = builder.build();
    final points = data.series[ImuFileVector.acceleration]!;
    expect(data.name, 'long.bin');
    expect(data.frameCount, 6001);
    expect(data.start, 0);
    expect(data.end, 60);
    expect(points.length, lessThanOrEqualTo(80));
    expect(points.first.time, 0);
    expect(points.last.time, 60);
    expect(points.map((p) => p.values.first), containsAll([-1000, 2000]));
  });

  test('keeps high rate navigation independently of position and raw TLVs', () {
    final builder = ImuFileBuilder('navigation.bin');
    for (var index = 0; index < 200; index++) {
      builder.add(
        _gps(index * 10000000)
          ..roll = 1
          ..pitch = 2
          ..yaw = 3
          ..ve = 4
          ..vn = 5
          ..vu = 6,
      );
    }
    builder.add(_gps(2000000000)..ax = 7);
    builder.add(_gps(2010000000)..wy = 8);
    builder.add(_gps(2020000000)..mz = 9);
    final data = builder.build();
    expect(data.series[ImuFileVector.attitude], hasLength(200));
    expect(data.series[ImuFileVector.attitude]!.first.values, [1, 2, 3]);
    expect(data.series[ImuFileVector.velocity]!.first.values, [4, 5, 6]);
    expect(data.series[ImuFileVector.acceleration]!.single.values, [
      7,
      null,
      null,
    ]);
    expect(data.series[ImuFileVector.gyroscope]!.single.values, [
      null,
      8,
      null,
    ]);
    expect(data.series[ImuFileVector.magnetic]!.single.values, [null, null, 9]);
  });

  test('subtracts full GPS week and nanos before converting to seconds', () {
    final builder = ImuFileBuilder('week.bin');
    builder.add(_gps(604799999999800, week: 2435)..ax = 1);
    builder.add(_gps(200, week: 2436)..ax = 2);
    final data = builder.build();
    expect(data.timeBasis, contains('GPS'));
    expect(data.end, closeTo(.0000004, 1e-15));
  });

  test(
    'uses validated UTC dates including full microseconds over midnight',
    () {
      final builder = ImuFileBuilder('utc.bin');
      builder.add(_utc(23, 59, 59, 999900)..ax = 1);
      builder.add(_utc(0, 0, 0, 100, day: 17)..ax = 2);
      final data = builder.build();
      expect(data.timeBasis, contains('UTC'));
      expect(data.end, closeTo(.0002, 1e-12));
    },
  );

  test('uses frame numbers when there is no common usable clock', () {
    final builder = ImuFileBuilder('index.bin');
    builder.add(ImuData()..ax = 1);
    builder.add(ImuData()..tempImu = 25);
    builder.add(_utc(25, 0, 0, 0)..ax = 3);
    builder.add(_gps(100)..ax = 4);
    final data = builder.build();
    expect(data.xAxisLabel, contains('帧'));
    expect(data.start, 0);
    expect(data.end, 3);
    expect(data.series[ImuFileVector.acceleration]!.map((p) => p.time), [
      0,
      2,
      3,
    ]);
    expect(data.frameCount, 4);
  });

  test(
    'starts UTC plots at synchronization and excludes placeholder frames',
    () {
      final builder = ImuFileBuilder('utc_sync.bin', maxPoints: 13);
      for (var index = 0; index < 50; index++) {
        builder.add(
          _utc(0, 0, index, 123456)
            ..utcYear = 2000
            ..utcMonth = 1
            ..utcDay = 1
            ..ax = -1000
            ..yaw = -90,
        );
      }
      builder.add(_utc(12, 0, 0, 100000)..ax = 1);
      builder.add(_utc(12, 0, 0, 110000)..yaw = 90);
      builder.add(_utc(12, 0, 1, 100000)..ax = 2);
      final data = builder.build();
      expect(data.timeBasis, contains('UTC'));
      expect(data.start, 0);
      expect(data.end, 1);
      expect(data.frameCount, 53);
      final acceleration = data.series[ImuFileVector.acceleration]!;
      expect(acceleration.map((point) => point.time), [0, 1]);
      expect(acceleration.map((point) => point.values[0]), [1, 2]);
      final attitude = data.series[ImuFileVector.attitude]!.single;
      expect(attitude.time, closeTo(.01, 1e-12));
      expect(attitude.values[2], 90);
    },
  );

  test('does not plot a file containing only unsynchronized UTC', () {
    final builder = ImuFileBuilder('unsynchronized.bin');
    builder.add(
      _utc(1, 2, 3, 456000)
        ..utcYear = 2000
        ..utcMonth = 1
        ..utcDay = 1
        ..ax = 1,
    );
    final data = builder.build();
    expect(data.isEmpty, isTrue);
    expect(data.frameCount, 1);
    expect(data.start, 0);
    expect(data.end, 0);
  });

  test('valid GPS remains usable alongside placeholder UTC', () {
    final builder = ImuFileBuilder('gps_with_placeholder.bin');
    for (var index = 0; index < 2; index++) {
      builder.add(
        _utc(0, 0, 0, 0)
          ..utcYear = 2000
          ..utcMonth = 1
          ..utcDay = 1
          ..gpsWeek = 2435
          ..gpsTowNanos = index * 10000000
          ..ax = index.toDouble(),
      );
    }
    final data = builder.build();
    expect(data.timeBasis, contains('GPS'));
    expect(data.series[ImuFileVector.acceleration], hasLength(2));
    expect(data.start, 0);
    expect(data.end, closeTo(.01, 1e-12));
  });

  test('marks clock resets and gaps without discarding older segments', () {
    final builder = ImuFileBuilder('reset.bin');
    for (final nanos in [0, 10000000, 20000000, 20000000000, 10000000]) {
      builder.add(_gps(nanos)..ax = 1);
    }
    final data = builder.build();
    final points = data.series[ImuFileVector.acceleration]!;
    expect(points, hasLength(5));
    expect(points[2].breakBefore, isFalse);
    expect(points[3].breakBefore, isTrue);
    expect(points[4].breakBefore, isTrue);
    expect(data.end, 20);
  });

  test('keeps invalid or unavailable axes null and respects alignment', () {
    final builder = ImuFileBuilder('invalid.bin');
    builder.add(
      ImuData()
        ..roll = 1
        ..pitch = 2
        ..yaw = 0
        ..ve = 0
        ..vn = 0
        ..vu = 0
        ..startupStage = 2,
    );
    builder.add(
      ImuData()
        ..roll = double.nan
        ..pitch = double.infinity
        ..yaw = 45
        ..ve = 0
        ..vn = double.nan,
    );
    builder.add(
      ImuData()
        ..roll = 3
        ..pitch = 4
        ..yaw = 90
        ..startupStage = 0
        ..fusionState = 4,
    );
    final data = builder.build();
    expect(data.series[ImuFileVector.attitude]![0].values, [1, 2, null]);
    expect(data.series[ImuFileVector.attitude]![1].values, [null, null, 45]);
    expect(data.series[ImuFileVector.attitude]![2].values, [null, null, null]);
    expect(data.series[ImuFileVector.velocity]![0].values, [null, null, null]);
    expect(data.series[ImuFileVector.velocity]![1].values, [0, null, null]);
  });

  test('dataset points and series are immutable snapshots', () {
    final builder = ImuFileBuilder('immutable.bin')..add(ImuData()..ax = 1);
    final first = builder.build();
    builder.add(ImuData()..ax = 2);
    expect(first.frameCount, 1);
    expect(first.series[ImuFileVector.acceleration], hasLength(1));
    expect(() => first.series.clear(), throwsUnsupportedError);
    expect(
      () => first.series[ImuFileVector.acceleration]!.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => first.series[ImuFileVector.acceleration]!.single.values[0] = 2,
      throwsUnsupportedError,
    );
    expect(
      () =>
          first.series[ImuFileVector.acceleration]!.single.axisBreaks[0] = true,
      throwsUnsupportedError,
    );
    expect(ImuFileBuilder('empty.bin').build().isEmpty, isTrue);
    expect(
      (ImuFileBuilder(
        'nan.bin',
      )..add(ImuData()..ax = double.nan)).build().isEmpty,
      isTrue,
    );
  });

  test('decimation preserves repeated missing-axis gaps independently', () {
    final builder = ImuFileBuilder('gaps.bin', maxPoints: 13);
    for (var frame = 0; frame <= 20; frame++) {
      builder.add(
        ImuData()
          ..ax = frame == 2 || frame == 10 ? double.nan : frame.toDouble()
          ..ay = frame == 9
              ? -100
              : frame == 11
              ? 100
              : 0
          ..az = 0,
      );
    }
    final points = builder.build().series[ImuFileVector.acceleration]!;
    final before = points.lastWhere((point) => point.time < 10);
    final after = points.firstWhere((point) => point.time > 10);
    expect(before.time, 9);
    expect(after.time, 11);
    expect(after.axisBreaks, [true, false, false]);
    expect(after.values, [11, 100, 0]);
    expect(after.breakBefore, isFalse);
  });

  test('GPS takes priority over a complete but stale UTC clock', () {
    final builder = ImuFileBuilder('gps_first.bin');
    for (var index = 0; index < 3; index++) {
      builder.add(
        _utc(1, 2, 3, 0)
          ..gpsWeek = 2435
          ..gpsTowNanos = index * 1234567
          ..yaw = index.toDouble(),
      );
    }
    final data = builder.build();
    expect(data.timeBasis, contains('GPS'));
    expect(data.end, closeTo(.002469134, 1e-15));
  });

  test('yaw wrapping breaks only yaw while roll and pitch stay continuous', () {
    final builder = ImuFileBuilder('yaw.bin');
    for (final yaw in [179.0, -179.0]) {
      builder.add(
        ImuData()
          ..roll = 1
          ..pitch = 2
          ..yaw = yaw,
      );
    }
    final point = builder.build().series[ImuFileVector.attitude]!.last;
    expect(point.axisBreaks, [false, false, true]);
    expect(point.breakBefore, isFalse);
  });

  test('controller replaces paths and keeps deterministic selections', () {
    final controller = ImuFileController();
    addTearDown(controller.dispose);
    final a = _dataset('a.bin');
    final b = _dataset('b.bin');
    controller.add(a);
    controller.add(b);
    expect(controller.selected, same(b));
    controller.select(a.sourcePath);
    expect(controller.selected, same(a));
    controller.select('unknown.bin');
    expect(controller.selected, same(a));
    controller.remove(b.sourcePath);
    expect(controller.selected, same(a));
    controller.add(_dataset(a.sourcePath));
    expect(controller.datasets, hasLength(1));
    controller.remove(a.sourcePath);
    expect(controller.selectedPath, isNull);
    controller.add(a);
    controller.select(null);
    expect(controller.selected, isNull);
    controller.clear();
    expect(controller.datasets, isEmpty);
  });

  test(
    'clear and remove prevent in-flight imports from restoring datasets',
    () async {
      final completions = <String, Completer<ImuFileDataset>>{};
      final controller = ImuFileController(
        loader: (path) {
          return (completions[path] = Completer<ImuFileDataset>()).future;
        },
      );
      addTearDown(controller.dispose);
      final first = controller.importFile('first.bin');
      controller.clear();
      completions['first.bin']!.complete(_dataset('first.bin'));
      await first;
      expect(controller.datasets, isEmpty);
      final second = controller.importFile('second.bin');
      controller.remove('second.bin');
      completions['second.bin']!.complete(_dataset('second.bin'));
      await second;
      expect(controller.datasets, isEmpty);
      final third = controller.importFile('third.bin');
      completions['third.bin']!.complete(_dataset('third.bin'));
      await third;
      expect(controller.selectedPath, 'third.bin');
    },
  );

  test('failed imports preserve the selected dataset', () async {
    final controller = ImuFileController(
      loader: (_) async => throw const FileSystemException('failed'),
    );
    addTearDown(controller.dispose);
    controller.add(_dataset('retained.bin'));
    await expectLater(
      controller.importFile('missing.bin'),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.selectedPath, 'retained.bin');
  });

  test(
    'streams mixed binary/ASCII files, skips corrupt frames, never broadcasts',
    () async {
      final directory = await Directory.systemTemp.createTemp('imu_file_data_');
      addTearDown(() => directory.delete(recursive: true));
      final corrupt = _frame(2, [0x10, 12, ..._xyz(99, 99, 99)])..last ^= 1;
      final prefix = ascii.encode('noise\r\n\$GNGGA,123\r\n');
      final bytes = <int>[
        ...prefix,
        ..._frame(1, [0x10, 12, ..._xyz(1000000, 0, -1000000)]),
        ...corrupt,
        ...ascii.encode('interleaved ASCII\r\n'),
        ..._frame(3, [0x40, 12, ..._xyz(2000000, 1000000, 90000000)]),
        0x59,
      ];
      // Force a valid frame to span a File.openRead chunk boundary.
      final padding = List.filled(65530 - prefix.length, 0x20);
      final input = File('${directory.path}${Platform.pathSeparator}mixed.bin');
      await input.writeAsBytes([...padding, ...bytes]);
      var liveEvents = 0;
      final subscription = ImuDataParser.imuDataStream.listen(
        (_) => liveEvents++,
      );
      addTearDown(subscription.cancel);
      final data = await loadImuFile(input.path);
      await Future<void>.delayed(Duration.zero);
      expect(data.frameCount, 2);
      expect(data.series[ImuFileVector.acceleration]!.single.values, [
        1,
        0,
        -1,
      ]);
      expect(data.series[ImuFileVector.attitude]!.single.values, [1, 2, 90]);
      expect(liveEvents, 0);
    },
  );
}

ImuData _gps(int nanos, {int week = 2435}) => ImuData()
  ..gpsWeek = week
  ..gpsTowNanos = nanos;

ImuData _utc(
  int hour,
  int minute,
  int second,
  int microseconds, {
  int day = 16,
}) => ImuData()
  ..utcYear = 2026
  ..utcMonth = 11
  ..utcDay = day
  ..utcHour = hour
  ..utcMin = minute
  ..utcSec = second
  ..utcUsec = microseconds;

ImuFileDataset _dataset(String path) =>
    (ImuFileBuilder(path)..add(ImuData()..ax = 1)).build();

List<int> _xyz(int x, int y, int z) {
  final bytes = ByteData(12)
    ..setInt32(0, x, Endian.little)
    ..setInt32(4, y, Endian.little)
    ..setInt32(8, z, Endian.little);
  return bytes.buffer.asUint8List();
}

List<int> _frame(int tid, List<int> payload) {
  final bytes = <int>[
    0x59,
    0x53,
    tid & 0xff,
    tid >> 8,
    payload.length,
    ...payload,
  ];
  var ck1 = 0;
  var ck2 = 0;
  for (final byte in bytes.skip(2)) {
    ck1 = (ck1 + byte) & 0xff;
    ck2 = (ck2 + ck1) & 0xff;
  }
  return [...bytes, ck1, ck2];
}
