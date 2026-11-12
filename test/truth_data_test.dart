import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/truth_data.dart';

void main() {
  test('reads named truth columns and ignores unused fields and units', () {
    final data = parseTruthText('''
Week, GPSTime, X-ECEF, VEast, VNorth, VUp, Roll, Pitch, Heading, Latitude, Longitude, H-Ell, Unused
week, (sec), (m), (m/s), (m/s), (m/s), (deg), (deg), (deg), (deg), (deg), (m),
2442,351158.000,ignored,-0.00344,0.00971,0.01163,-1.4713785362,-2.1610191863,359.523539345,30.528142357,114.355708938,21.4437,not-a-number
''', sourcePath: 'truth.pos');
    final sample = data.samples.single;
    expect(sample.utcTime, DateTime.utc(2026, 10, 29, 1, 32, 20));
    expect(sample.latitude, 30.528142357);
    expect(sample.longitude, 114.355708938);
    expect(sample.height, 21.4437);
    expect(sample.velocityEast, -0.00344);
    expect(sample.velocityNorth, 0.00971);
    expect(sample.velocityUp, 0.01163);
    expect(sample.roll, -1.4713785362);
    expect(sample.pitch, -2.1610191863);
    expect(sample.heading, 359.523539345);
    expect(data.sourcePath, 'truth.pos');
    expect(data.mapping[TruthField.latitude], 9);
    expect(data.skippedRows, 0);
    expect(() => data.samples.clear(), throwsUnsupportedError);
  });

  test(
    'manual mapping supports reordered headerless data and optional gaps',
    () {
      final mapping = TruthColumnMapping(
        columns: {
          TruthField.gpsWeek: 0,
          TruthField.longitude: 1,
          TruthField.latitude: 2,
          TruthField.gpsSeconds: 3,
          TruthField.height: 4,
          TruthField.velocityEast: 9,
        },
        delimiter: 'whitespace',
      );
      final data = parseTruthText('''
# Data may omit optional measurements.
2442 114.35 3.05D1 351158 NaN
2442 114.35 91 351159 35
2442 114.35 NaN 351160 35
2442 181 30.5 351161 35
2442 114.35 30.5 604800 35
''', mapping: mapping);
      expect(data.samples, hasLength(1));
      expect(data.samples.single.latitude, 30.5);
      expect(data.samples.single.height, isNull);
      expect(data.samples.single.velocityEast, isNull);
      expect(data.skippedRows, 4);
    },
  );

  test('sorts epochs and retains the last valid duplicate', () {
    final data = parseTruthText('''
UTC Latitude Longitude Yaw
2026-10-29T01:32:22Z 32 114 359
2026-10-29T01:32:20Z 30 114 1
2026-10-29T01:32:22Z 33 114 0
2026-10-29T01:32:22Z NaN 114 90
''');
    expect(data.samples.map((sample) => sample.latitude), [30.0, 33.0]);
    expect(data.samples.last.heading, 0);
    expect(data.skippedRows, 1);
  });

  test('supports UTC zone-less, offset ISO and Unix time columns', () {
    for (final (time, expected) in [
      ('2026-10-29T01:32:20', DateTime.utc(2026, 10, 29, 1, 32, 20)),
      ('2026-10-29 01:32:20', DateTime.utc(2026, 10, 29, 1, 32, 20)),
      ('2026-10-29T09:32:20+08:00', DateTime.utc(2026, 10, 29, 1, 32, 20)),
      (
        '1000000000.125',
        DateTime.fromMicrosecondsSinceEpoch(1000000000125000, isUtc: true),
      ),
    ]) {
      final sample = parseTruthText(
        'Timestamp,Lat,Lon\n"$time",30,114',
      ).samples.single;
      expect(sample.utcTime, expected);
      expect(sample.utcTime.isUtc, isTrue);
      expect(sample.height, isNull);
      expect(sample.roll, isNull);
    }
  });

  test('detects tab-separated aliases and commented headers', () {
    final data = parseTruthText(
      '\uFEFF# GPSWeek\tTOW\tLAT\tLNG\tVE\tVN\tVU\tAZIMUTH\n'
      '2442\t351158\t30.5\t114.3\t1\t2\t3\t359.5',
    );
    expect(data.samples.single.velocityNorth, 2);
    expect(data.samples.single.heading, 359.5);
    expect(data.mapping.delimiter, '\t');
  });

  test('ISO calendar and clock validation rejects normalized timestamps', () {
    final text = StringBuffer('UTC,Latitude,Longitude\n');
    for (final invalid in [
      '2026-02-30T01:32:20Z',
      '2026-13-01T01:32:20Z',
      '2026-10-00T01:32:20Z',
      '2026-10-29T24:00:00Z',
      '2026-10-29T01:60:00Z',
      '2026-10-29T01:32:60Z',
      '2026-10-29T01:32:20+24:00',
      '2026-10-29T01:32:20+08:60',
    ]) {
      text.writeln('$invalid,30,114');
    }
    text.writeln('2024-02-29T23:32:20.123456-02:00,30,114');
    final data = parseTruthText(text.toString());
    expect(data.skippedRows, 8);
    expect(
      data.samples.single.utcTime,
      DateTime.utc(2024, 3, 1, 1, 32, 20, 123, 456),
    );
  });

  test('GPS UTC correction is explicit and validates time ranges', () {
    final utc = gpsTimeToUtc(2442, 351158.123456);
    expect(utc, DateTime.utc(2026, 10, 29, 1, 32, 20, 123, 456));
    expect(
      gpsTimeToUtc(
        2442,
        351158,
        gpsUtcOffsetSeconds: 0,
      ).difference(utc).inMicroseconds,
      17876544,
    );
    expect(() => gpsTimeToUtc(-1, 0), throwsFormatException);
    expect(() => gpsTimeToUtc(2442, double.nan), throwsFormatException);
    expect(() => gpsTimeToUtc(2442, 604800), throwsFormatException);
    expect(
      () => gpsTimeToUtc(2442, 0, gpsUtcOffsetSeconds: 61),
      throwsFormatException,
    );
  });

  test('missing mandatory columns and wholly invalid input fail clearly', () {
    expect(() => parseTruthText('2442,351158,30,114'), throwsFormatException);
    expect(
      () => parseTruthText('Week,GPSTime,Latitude\n2442,351158,30'),
      throwsFormatException,
    );
    expect(
      () => parseTruthText('Latitude,Longitude\n30,114'),
      throwsFormatException,
    );
    expect(
      () => parseTruthText('Week,GPSTime,Latitude,Longitude\n2442,NaN,30,114'),
      throwsFormatException,
    );
    expect(
      () => parseTruthText(
        '',
        mapping: TruthColumnMapping(
          columns: {
            TruthField.gpsWeek: 0,
            TruthField.gpsSeconds: 1,
            TruthField.latitude: -1,
            TruthField.longitude: 3,
          },
        ),
      ),
      throwsFormatException,
    );
  });

  test('file preview and streaming reader share column detection', () async {
    final directory = Directory.systemTemp.createTempSync('truth_reader_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/truth.pos');
    final text = StringBuffer(
      'Week,GPSTime,Latitude,Longitude,Heading,unused\n',
    );
    for (var i = 0; i < 2000; i++) {
      text.writeln(
        '2442,${351158 + i},30.528142357,114.355708938,359.5,ignored-long-column',
      );
    }
    file.writeAsStringSync(text.toString());
    final preview = await previewTruthFile(file.path);
    expect(preview.headers, hasLength(6));
    expect(preview.headerLineIndex, 0);
    expect(preview.mapping[TruthField.heading], 4);
    expect(preview.exampleRows, hasLength(3));
    final data = await readTruthFile(file.path, mapping: preview.mapping);
    expect(data.samples, hasLength(2000));
    expect(
      data.samples.last.utcTime
          .difference(data.samples.first.utcTime)
          .inSeconds,
      1999,
    );
    expect(data.skippedRows, 0);
    expect(data.headers, preview.headers);
  });

  test('headerless preview exposes all columns for manual selection', () async {
    final directory = Directory.systemTemp.createTempSync('truth_preview_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/truth.txt')
      ..writeAsStringSync('2442 351158 30 114\n');
    final preview = await previewTruthFile(file.path);
    expect(preview.headerLineIndex, isNull);
    expect(preview.headers, ['列 1', '列 2', '列 3', '列 4']);
    expect(preview.mapping.columns, isEmpty);
    expect(preview.exampleRows.single, ['2442', '351158', '30', '114']);
  });
}
