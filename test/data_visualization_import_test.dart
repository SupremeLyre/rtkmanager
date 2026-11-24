import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/imu_file_data.dart';
import 'package:rtkmanager/imu_visualization_page.dart';

class _Picker extends FilePicker {
  _Picker(this.path);
  final String? path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => path == null
      ? null
      : FilePickerResult([
          PlatformFile(name: 'offline.bin', path: path, size: 0),
        ]);
}

void main() {
  testWidgets('removing a source cancels its pending visualization import', (
    tester,
  ) async {
    final completion = Completer<ImuFileDataset>();
    var reading = false;
    final files = ImuFileController(
      loader: (_) {
        reading = true;
        return completion.future;
      },
    );
    addTearDown(files.dispose);
    final path = File('test/fixtures/phone_imu_paired.bin').absolute.path;
    FilePicker.platform = _Picker(path);
    await tester.pumpWidget(
      MaterialApp(
        home: ImuVisualizationPage(
          files: files,
          dataStream: const Stream<ImuData>.empty(),
          sourceLabel: '实时源',
          emptyMessage: '等待采集',
          onOpenDrawer: () {},
        ),
      ),
    );
    await tester.tap(find.widgetWithText(OutlinedButton, '导入数据'));
    await tester.pump();
    expect(reading, isTrue);
    files.remove(path);
    completion.complete((ImuFileBuilder(path)..add(ImuData()..ax = 1)).build());
    await tester.pump();
    expect(files.datasets, isEmpty);
    expect(find.text('离线文件'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'shared imported files remain selected across live source changes',
    (tester) async {
      final files = ImuFileController();
      addTearDown(files.dispose);
      final first = StreamController<ImuData>.broadcast();
      final second = StreamController<ImuData>.broadcast();
      addTearDown(first.close);
      addTearDown(second.close);
      Widget page(Stream<ImuData> stream) => MaterialApp(
        home: ImuVisualizationPage(
          files: files,
          dataStream: stream,
          sourceLabel: '实时源',
          emptyMessage: '等待采集',
          onOpenDrawer: () {},
        ),
      );
      await tester.pumpWidget(page(first.stream));
      final builder = ImuFileBuilder('navigation.bin')
        ..add(
          ImuData()
            ..roll = 1
            ..pitch = 2
            ..yaw = 3
            ..ve = 4
            ..vn = 5
            ..vu = 6,
        );
      files.add(builder.build());
      await tester.pump();
      expect(find.text('离线文件'), findsOneWidget);
      expect(find.textContaining('已解析 1 帧'), findsOneWidget);
      await tester.pumpWidget(page(second.stream));
      expect(find.textContaining('已解析 1 帧'), findsOneWidget);
      expect(first.hasListener, isFalse);
      second.add(
        ImuData()
          ..ax = 1
          ..ay = 2
          ..az = 3,
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, '返回实时'));
      await tester.pump();
      expect(find.textContaining('已接收 1 帧'), findsOneWidget);
      files.remove('navigation.bin');
      await tester.pump();
      expect(find.textContaining('已接收 1 帧'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('imports recorded raw observations and returns to live data', (
    tester,
  ) async {
    final stream = StreamController<ImuData>.broadcast();
    addTearDown(stream.close);
    FilePicker.platform = _Picker(
      File('test/fixtures/phone_imu_paired.bin').absolute.path,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ImuVisualizationPage(
          dataStream: stream.stream,
          sourceLabel: '测试实时源',
          emptyMessage: '等待采集',
          onOpenDrawer: () {},
        ),
      ),
    );
    expect(find.text('数据可视化'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(OutlinedButton, '导入数据'));
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (find.text('离线文件').evaluate().isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
    expect(find.text('离线文件'), findsOneWidget);
    expect(find.textContaining('phone_imu_paired.bin'), findsWidgets);
    expect(find.textContaining('已解析'), findsOneWidget);
    expect(find.byKey(const ValueKey('imu-pause')), findsNothing);
    stream.add(
      ImuData()
        ..ax = 1
        ..ay = 2
        ..az = 3,
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.widgetWithText(OutlinedButton, '返回实时'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('已接收 1 帧'), findsOneWidget);

    FilePicker.platform = _Picker(null);
    await tester.tap(find.widgetWithText(OutlinedButton, '导入数据'));
    await tester.pump();
    expect(find.textContaining('已接收 1 帧'), findsOneWidget);
    expect(find.text('离线文件'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
