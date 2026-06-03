import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';

void main() {
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
