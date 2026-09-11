import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_batch_decode_page.dart';

void main() {
  late Directory directory;
  late File input;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('imu_decode_test_');
    input = File('${directory.path}${Platform.pathSeparator}mixed.bin')
      ..writeAsBytesSync([
        ..._frame(65532, 100000, _rawImu),
        ..._frame(65533, 110000, _rawImu),
        // Navigation arrives after a newer IMU sample, using a shared TID.
        ..._frame(65534, 100000, _navigation),
        ..._frame(65535, 120000, _rawImu),
        ..._frame(0, 110000, _navigation),
        // Older firmware can include raw IMU and navigation in the same frame.
        ..._frame(1, 130000, [..._rawImu, ..._navigation]),
        // Real zero measurements must be retained; absence is not a zero value.
        ..._frame(2, 140000, [
          0x10,
          12,
          ...List.filled(12, 0),
          0x20,
          12,
          ...List.filled(12, 0),
        ]),
        ..._frame(3, 150000, [0x01, 2, 0, 0]),
      ]);
    FilePicker.platform = _TestFilePicker(input.path);
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  for (final compensate in [true, false]) {
    testWidgets('IMU export skips delayed navigation (TID: $compensate)', (
      tester,
    ) async {
      final rows = await _decode(
        tester,
        input,
        navigationOnly: false,
        compensate: compensate,
      );

      expect(rows.first, 'GPSWeek,GPSSow,gx,gy,gz,ax,ay,az');
      expect(rows.length, 6);
      final data = rows.skip(1).map((row) => row.split(',')).toList();
      expect(data.map((row) => row[1]), [
        '475218.100000',
        '475218.110000',
        '475218.120000',
        '475218.130000',
        '475218.140000',
      ]);
      for (final row in data.take(4)) {
        expect(row.skip(2).map(double.parse), [1, -2, 3, 1, -2, 3]);
      }
      expect(data.last.skip(2).map(double.parse), List.filled(6, 0));
    });
  }

  testWidgets('navigation export keeps separate and combined results', (
    tester,
  ) async {
    final rows = await _decode(tester, input, navigationOnly: true);

    expect(rows.first, 'GPSWeek,GPSSow,fusionState,gnssState');
    expect(rows.skip(1), [
      '2435,475218.100000,4,5',
      '2435,475218.110000,4,5',
      '2435,475218.130000,4,5',
    ]);
  });
}

Future<List<String>> _decode(
  WidgetTester tester,
  File input, {
  required bool navigationOnly,
  bool compensate = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ImuBatchDecodePage(onOpenDrawer: () {})),
    ),
  );
  Future<void> toggle(String label) async {
    final row = find.ancestor(of: find.text(label), matching: find.byType(Row));
    await tester.tap(find.descendant(of: row, matching: find.byType(Checkbox)));
    await tester.pump();
  }

  if (!navigationOnly) await toggle('只解码组合导航结果');
  if (!compensate) await toggle('使用TID补偿时间戳');
  if (navigationOnly) await toggle('输出状态');
  await tester.tap(find.text('导入文件'));
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.text('开始解码'));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (find.text('完成').evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
      expect(find.text('错误'), findsNothing);
    }
  });
  expect(find.text('完成'), findsOneWidget);
  return File('${input.path}.csv').readAsLinesSync();
}

const _navigation = [0x80, 1, 0x54];
final _rawImu = [
  for (final id in [0x10, 0x20]) ...[
    id,
    12,
    ..._le(1000000, 4),
    ..._le(-2000000, 4),
    ..._le(3000000, 4),
  ],
];

List<int> _frame(int tid, int usec, List<int> payload) {
  final fields = [
    ...payload,
    0x50,
    11,
    ..._le(usec ~/ 1000, 4),
    ..._le(26, 2),
    9,
    11,
    12,
    0,
    0,
    0x51,
    4,
    ..._le(usec, 4),
  ];
  final bytes = [0x59, 0x53, ..._le(tid, 2), fields.length, ...fields];
  int ck1 = 0;
  int ck2 = 0;
  for (final byte in bytes.skip(2)) {
    ck1 = (ck1 + byte) & 0xff;
    ck2 = (ck2 + ck1) & 0xff;
  }
  return [...bytes, ck1, ck2];
}

List<int> _le(int value, int length) => [
  for (int i = 0; i < length; i++) (value >> (8 * i)) & 0xff,
];

class _TestFilePicker extends FilePicker {
  _TestFilePicker(this.path);
  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(path: path, name: 'mixed.bin', size: File(path).lengthSync()),
  ]);
}
