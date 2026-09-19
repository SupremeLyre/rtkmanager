import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/gga_log_service.dart';

const first =
    r'$GPGGA,235959.00,3031.7071,N,11421.4181,E,6,18,0.8,35.2,M,0,M,1.0,0000';
const second =
    r'$GPGGA,000000.00,3031.8071,N,11421.5181,E,0,18,0.8,35.2,M,0,M,1.0,0000';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late StreamController<String> messages;
  late GgaLogService service;
  late DateTime now;
  const channel = MethodChannel('test/gga_logs');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gga_logs_');
    messages = StreamController<String>.broadcast(sync: true);
    now = DateTime.utc(2026, 9, 18, 23, 59, 59);
    service = GgaLogService(
      messages: messages.stream,
      directory: () async => directory,
      clock: () => now,
      methods: channel,
    );
    await service.ready;
  });

  tearDown(() async {
    service.dispose();
    await service.flush();
    await messages.close();
    await directory.delete(recursive: true);
    messenger.setMockMethodCallHandler(channel, null);
  });

  File file(String name) => File('${directory.path}/$name');

  test(
    'uses UTC reception date, including non-UTC offsets and midnight',
    () async {
      final gate = Completer<void>();
      final blocked = GgaLogService(
        messages: messages.stream,
        directory: () async {
          await gate.future;
          return directory;
        },
        clock: () => now,
      );
      service.dispose();
      await service.flush();
      service = blocked;
      now = DateTime.parse('2026-09-19T07:59:59+08:00');
      messages.add(first);
      now = DateTime.parse('2026-09-19T08:00:00+08:00');
      messages.add(second);
      gate.complete();
      await service.flush();
      expect(await file('GGA20260918.txt').readAsString(), '$first\r\n');
      expect(await file('GGA20260919.txt').readAsString(), '$second\r\n');
      expect((await service.listFiles()).map((entry) => entry.name), [
        'GGA20260919.txt',
        'GGA20260918.txt',
      ]);
    },
  );

  test(
    'appends ordered raw lines and resumes the same file after restart',
    () async {
      for (var i = 0; i < 100; i++) {
        messages.add(i.isEven ? first : second);
      }
      service.dispose();
      await service.flush();
      service = GgaLogService(
        messages: messages.stream,
        directory: () async => directory,
        clock: () => now,
        methods: channel,
      );
      messages.add(first);
      await service.flush();
      final expected = [
        for (var i = 0; i < 100; i++) i.isEven ? first : second,
        first,
      ].map((line) => '$line\r\n').join();
      expect(await file('GGA20260918.txt').readAsString(), expected);
      final entries = await service.listFiles();
      expect(entries.length, 1);
      expect(
        entries.single.modified,
        (await file(entries.single.name).stat()).modified,
      );
    },
  );

  test(
    'deleting an active log removes old data and subsequent GGA recreates it',
    () async {
      messages.add(first);
      final deletion = service.delete('GGA20260918.txt');
      await deletion;
      expect(await file('GGA20260918.txt').exists(), isFalse);
      expect(await service.listFiles(), isEmpty);
      messages.add(second);
      await service.flush();
      expect(await file('GGA20260918.txt').readAsString(), '$second\r\n');
      expect(service.error, isNull);
    },
  );

  test(
    'open and share invoke native APIs only after preceding data is written',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        expect(call.arguments, {'name': 'GGA20260918.txt'});
        expect(
          await file('GGA20260918.txt').readAsString(),
          '$first\r\n$second\r\n',
        );
        return null;
      });
      messages.add(first);
      messages.add(second);
      await service.open('GGA20260918.txt');
      await service.share('GGA20260918.txt');
      expect(calls, ['openLog', 'shareLog']);
      await service.delete('GGA20260918.txt');
      await expectLater(
        service.open('GGA20260918.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(calls.length, 2);
    },
  );

  test(
    'lists only daily logs and refuses paths outside the log directory',
    () async {
      await file('unrelated.txt').writeAsString('keep');
      await expectLater(
        service.delete('../unrelated.txt'),
        throwsArgumentError,
      );
      expect(await file('unrelated.txt').readAsString(), 'keep');
      expect(await service.listFiles(), isEmpty);
    },
  );

  test(
    'storage initialization failure is visible and later messages can recover',
    () async {
      service.dispose();
      await service.flush();
      var unavailable = true;
      service = GgaLogService(
        messages: messages.stream,
        directory: () async {
          if (unavailable) {
            throw const FileSystemException('storage unavailable');
          }
          return directory;
        },
        clock: () => now,
      );
      await service.ready;
      messages.add(first);
      await service.flush();
      expect(service.error, contains('storage unavailable'));
      unavailable = false;
      messages.add(second);
      await service.flush();
      expect(await file('GGA20260918.txt').readAsString(), '$second\r\n');
    },
  );
}
