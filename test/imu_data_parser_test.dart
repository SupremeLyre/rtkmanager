import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';

void main() {
  test('fusion readiness separates horizontal alignment from INS heading', () {
    for (final state in <int?>[null, 0, 1, 2, 3, 4, 5, 6, 15]) {
      final sample = ImuData()..fusionState = state;
      expect(sample.horizontalAttitudeReady, [1, 4, 5].contains(state));
      expect(sample.headingReady, [4, 5].contains(state));
    }
  });

  test('startup stage takes precedence over legacy fusion readiness', () {
    for (final stage in [0, 1, 2, 3, 4, 255]) {
      for (final fusion in <int?>[null, 1, 4, 5]) {
        final sample = ImuData()
          ..startupStage = stage
          ..fusionState = fusion;
        expect(sample.horizontalAttitudeReady, [1, 2, 3].contains(stage));
        expect(sample.headingReady, stage == 3);
      }
    }
  });

  test(
    'decodes startup stage and preserves horizontal to heading transition',
    () {
      final samples = <ImuData>[];
      final frames = [
        ..._frame(1, [0x80, 1, 0x44, 0x85, 1, 2]),
        ..._frame(2, [0x80, 1, 0x44, 0x85, 1, 3]),
        ..._frame(3, [0x80, 1, 0x05]),
        ..._frame(4, [0x80, 1, 0x44, 0x85, 1, 0]),
      ];
      final parser = ImuDataParser();
      for (var offset = 0; offset < frames.length; offset += 3) {
        parser.parseData(
          frames.sublist(offset, (offset + 3).clamp(0, frames.length)),
          samples.add,
          broadcast: false,
        );
      }
      expect(samples, hasLength(4));
      expect(samples[0].startupStage, 2);
      expect(samples[0].fusionState, 4);
      expect(samples[0].gnssState, 4);
      expect(samples[0].horizontalAttitudeReady, isTrue);
      expect(samples[0].headingReady, isFalse);
      expect(samples[1].startupStage, 3);
      expect(samples[1].headingReady, isTrue);
      expect(samples[2].startupStage, isNull);
      expect(samples[2].fusionState, 5);
      expect(samples[2].headingReady, isTrue);
      expect(samples[3].startupStage, 0);
      expect(samples[3].horizontalAttitudeReady, isFalse);
      expect(samples[3].headingReady, isFalse);
    },
  );

  test('malformed startup TLV lengths are skipped without losing status', () {
    final samples = <ImuData>[];
    ImuDataParser().parseData(
      [
        ..._frame(1, [0x85, 0, 0x80, 1, 0x41]),
        ..._frame(2, [0x85, 2, 3, 0, 0x80, 1, 0x44]),
        ..._frame(3, [0x85, 2, 3]),
      ],
      samples.add,
      broadcast: false,
    );
    expect(samples, hasLength(3));
    expect(samples.every((sample) => sample.startupStage == null), isTrue);
    expect(samples[0].fusionState, 1);
    expect(samples[0].horizontalAttitudeReady, isTrue);
    expect(samples[0].headingReady, isFalse);
    expect(samples[1].fusionState, 4);
    expect(samples[1].headingReady, isTrue);
    expect(samples[2].fusionState, isNull);
    expect(samples[2].horizontalAttitudeReady, isFalse);
    expect(samples[2].headingReady, isFalse);
  });

  test('unknown startup stages are retained but do not certify attitude', () {
    final samples = <ImuData>[];
    ImuDataParser().parseData(
      _frame(1, [0x80, 1, 0x44, 0x85, 1, 99]),
      samples.add,
      broadcast: false,
    );
    expect(samples.single.startupStage, 99);
    expect(samples.single.horizontalAttitudeReady, isFalse);
    expect(samples.single.headingReady, isFalse);
  });

  test('native paired IMU frame produces exactly one six-axis record', () {
    final result = <ImuData>[];
    ImuDataParser().parseData(
      File('test/fixtures/phone_imu_paired.bin').readAsBytesSync(),
      result.add,
      broadcast: false,
    );
    expect(result, hasLength(1));
    expect(result.single.ax, 1);
    expect(result.single.ay, 0);
    expect(result.single.az, -1);
    expect(result.single.wx, closeTo(180, .00001));
    expect(result.single.wy, 0);
    expect(result.single.wz, 0);
    expect(result.single.gpsTowNanos, 123456123456789);
  });
  test('parses actual native sensor frames with GPST and independent axes', () {
    final fixture = File('test/fixtures/phone_sensors.bin').readAsBytesSync();
    final result = <ImuData>[];
    final parser = ImuDataParser();
    for (var i = 0; i < fixture.length; i += 7) {
      parser.parseData(
        fixture.sublist(i, (i + 7).clamp(0, fixture.length)),
        result.add,
        broadcast: false,
      );
    }
    expect(result.length, 3);
    expect(result.first.ax, 1);
    expect(result.first.az, -1);
    expect(result.first.wx, isNull);
    expect(result[1].wx, closeTo(180, .00001));
    expect(result[1].ax, isNull);
    expect(result.last.hasMag, isTrue);
    expect(result.last.mx, 10.25);
    expect(result.last.my, -20.5);
    expect(result.last.mz, 0);
    for (final sample in result) {
      expect(sample.gpsWeek, 2400);
      expect(sample.gpsTowNanos, 123456123456789);
      expect(sample.utcUsec, 123456);
    }
  });

  test('firmware debug TLVs do not become magnetic samples', () {
    final values = <ImuData>[];
    ImuDataParser().parseData(
      _frame(4, [
        0x81,
        4,
        1,
        2,
        3,
        4,
        0x82,
        4,
        5,
        6,
        7,
        8,
        0x83,
        4,
        9,
        0,
        0,
        0,
      ]),
      values.add,
      broadcast: false,
    );
    expect(values.single.hasMag, isFalse);
    expect(values.single.gpsWeek, isNull);
  });

  test('trailing incomplete TLV does not crash the parser', () {
    final values = <ImuData>[];
    ImuDataParser().parseData(_frame(4, [0x30]), values.add, broadcast: false);
    expect(values.single.hasMag, isFalse);
  });
  test('parses UTC microsecond extension', () {
    final frame = _frame(7, [
      0x50,
      11,
      ..._u32le(123),
      ..._u16le(26),
      6,
      3,
      12,
      34,
      56,
      0x51,
      4,
      ..._u32le(123456),
    ]);

    ImuData? parsed;
    ImuDataParser().parseData(frame, (data) {
      parsed = data;
    }, broadcast: false);

    expect(parsed, isNotNull);
    expect(parsed!.tid, 7);
    expect(parsed!.utcYear, 2026);
    expect(parsed!.utcMsec, 123);
    expect(parsed!.utcUsec, 123456);
    expect(parsed!.utcSubsecondUsec, 123456);
    expect(parsed!.utcDateTimeMsec, 123);
    expect(parsed!.utcDateTimeUsec, 456);
    expect(parsed!.isUtcWholeSecond, isFalse);
    expect(parsed!.utcFractionText, '123456');
  });

  test('keeps millisecond-only UTC frames compatible', () {
    final frame = _frame(8, [
      0x50,
      11,
      ..._u32le(0),
      ..._u16le(26),
      6,
      3,
      12,
      34,
      56,
    ]);

    ImuData? parsed;
    ImuDataParser().parseData(frame, (data) {
      parsed = data;
    }, broadcast: false);

    expect(parsed, isNotNull);
    expect(parsed!.utcMsec, 0);
    expect(parsed!.utcUsec, isNull);
    expect(parsed!.utcSubsecondUsec, 0);
    expect(parsed!.isUtcWholeSecond, isTrue);
    expect(parsed!.utcFractionText, '000');
  });
}

List<int> _frame(int tid, List<int> payload) {
  final bytes = <int>[0x59, 0x53, ..._u16le(tid), payload.length, ...payload];
  int ck1 = 0;
  int ck2 = 0;
  for (var i = 2; i < bytes.length; i++) {
    ck1 = (ck1 + bytes[i]) & 0xFF;
    ck2 = (ck2 + ck1) & 0xFF;
  }
  bytes
    ..add(ck1)
    ..add(ck2);
  return bytes;
}

List<int> _u16le(int value) => [value & 0xFF, (value >> 8) & 0xFF];

List<int> _u32le(int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];
