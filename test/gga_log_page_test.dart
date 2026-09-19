import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/android_app_frame.dart';
import 'package:rtkmanager/gga_log_page.dart';
import 'package:rtkmanager/gga_log_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'SourceHanSansHWSC',
    )..addFont(rootBundle.load('fonts/SourceHanSansHWSC-Regular.otf'))).load();
  });

  for (final (size, scale) in [
    (const Size(320, 640), 1.0),
    (const Size(320, 640), 2.0),
    (const Size(640, 360), 1.0),
  ]) {
    testWidgets('log path, timestamp and file actions fit $size / $scale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      late Directory directory;
      late File file;
      late GgaLogService service;
      const channel = MethodChannel('test/log_page');
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call.method);
        expect(call.arguments, {'name': 'GGA20260918.txt'});
        return null;
      });
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('gga_log_page_');
        file = File('${directory.path}/GGA20260918.txt');
        await file.writeAsString('GGA data\r\n');
        await file.setLastModified(DateTime.utc(2026, 9, 18, 12, 34, 56));
        service = GgaLogService(
          messages: const Stream.empty(),
          directory: () async => directory,
          methods: channel,
        );
        await service.ready;
      });
      addTearDown(() async {
        await tester.runAsync(() async {
          service.dispose();
          var closed = false;
          unawaited(service.flush().then((_) => closed = true));
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!closed && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
          expect(closed, isTrue);
          await directory.delete(recursive: true);
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });

      Future<void> waitUntil(bool Function() complete) async {
        await tester.runAsync(() async {
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!complete() && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        expect(complete(), isTrue);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'SourceHanSansHWSC'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: AndroidAppFrame(child: child!),
          ),
          home: GgaLogPage(service: service, onOpenDrawer: () {}, active: true),
        ),
      );
      await waitUntil(() => find.text('1').evaluate().isNotEmpty);
      await tester.scrollUntilVisible(
        find.text(directory.path),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(directory.path), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('GGA20260918.txt'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('修改时间（UTC）\n2026-09-18 12:34:56'), findsOneWidget);
      expect(find.text('日志存储'), findsOneWidget);
      for (final (label, method) in [('打开', 'openLog'), ('分享', 'shareLog')]) {
        final button = find.widgetWithText(TextButton, label);
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        expect(button.hitTestable(), findsOneWidget);
        await tester.tap(button);
        await waitUntil(
          () =>
              calls.contains(method) &&
              tester.widget<TextButton>(button).onPressed != null,
        );
      }
      final delete = find.widgetWithText(TextButton, '删除');
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await waitUntil(() => find.text('GGA20260918.txt').evaluate().isEmpty);
      expect(await tester.runAsync(file.exists), isFalse);
      expect(calls, ['openLog', 'shareLog']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
