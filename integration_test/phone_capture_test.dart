// Real-device test: requires location permission and a current GNSS clock.
// Records a new session; never synthesizes sensor data or changes the clock gate.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/main.dart' as app;
import 'package:rtkmanager/phone_capture_service.dart';

Future<Map<String, dynamic>> status() async => Map<String, dynamic>.from(
  (await PhoneCaptureService.channel.invokeMapMethod<String, dynamic>(
    'status',
  ))!,
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real IMU capture, magnetic limit, charts and saved frames',
    (tester) async {
      await app.main();
      await tester.pump(const Duration(seconds: 1));
      final before = await status();
      expect(
        before['mode'],
        'idle',
        reason: 'Stop an existing capture before running this test.',
      );
      var startedByTest = false;
      try {
        await tester.tap(find.byTooltip('打开导航').first);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('android-nav-3')),
          160,
          scrollable: find
              .descendant(
                of: find.byType(Drawer),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(const ValueKey('android-nav-3')));
        await tester.pump(const Duration(milliseconds: 400));
        Future<void> show(String key, {double delta = 200}) async {
          await tester.scrollUntilVisible(
            find.byKey(ValueKey(key)),
            delta,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pump(const Duration(milliseconds: 200));
        }

        await show('capture-probe');
        await tester.tap(find.byKey(const ValueKey('capture-probe')));
        startedByTest = true;
        Map<String, dynamic> state = {};
        for (var attempt = 0; attempt < 50; attempt++) {
          await tester.pump(const Duration(seconds: 1));
          state = await status();
          final sensors = state['sensors'] as Map?;
          if (state['timeReady'] == true &&
              sensors?['imu']?['available'] == true &&
              sensors?['mag']?['available'] == true) {
            break;
          }
        }
        expect(
          state['timeReady'],
          true,
          reason: 'This test requires a real GNSS elapsedRealtime time anchor.',
        );
        await show('capture-imu');
        await tester.tap(find.byKey(const ValueKey('capture-imu')));
        await show('capture-mag');
        await tester.tap(find.byKey(const ValueKey('capture-mag')));
        await show('mag-rate');
        await tester.tap(find.byKey(const ValueKey('mag-rate')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('100 Hz').last);
        await tester.pump(const Duration(milliseconds: 300));
        await show('capture-start', delta: -220);
        await tester.tap(find.byKey(const ValueKey('capture-start')));
        await tester.pump(const Duration(seconds: 2));
        expect((await status())['mode'], 'recording');
        await tester.tap(find.byKey(const ValueKey('capture-open-imu')));
        await tester.pump(const Duration(seconds: 8));
        expect(find.text('IMU 数据可视化'), findsOneWidget);
        expect(find.text('等待 IMU 数据'), findsNothing);
        final running = await status();
        final countBeforePause = (running['counts'] as Map)['imu'] as int;
        expect(countBeforePause, greaterThan(100));
        expect((running['counts'] as Map)['mag'], greaterThan(50));
        await show('imu-pause');
        await tester.tap(find.byKey(const ValueKey('imu-pause')));
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('显示已暂停'), findsOneWidget);
        expect(
          (await status())['counts']['imu'],
          greaterThan(countBeforePause),
        );
        await tester.tap(find.byKey(const ValueKey('imu-pause')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('打开数据源'));
        await tester.pump(const Duration(milliseconds: 300));
        await show('capture-stop', delta: -220);
        await tester.tap(find.byKey(const ValueKey('capture-stop')));
        await tester.pump(const Duration(seconds: 1));
        state = await status();
        expect(state['mode'], 'idle');
        final path = state['path'] as String;
        final imu = <ImuData>[];
        final mag = <ImuData>[];
        ImuDataParser().parseData(
          await File('$path/imu.bin').readAsBytes(),
          imu.add,
          broadcast: false,
        );
        ImuDataParser().parseData(
          await File('$path/mag.bin').readAsBytes(),
          mag.add,
          broadcast: false,
        );
        expect(imu.length, (state['counts'] as Map)['imu']);
        expect(mag.length, (state['counts'] as Map)['mag']);
        expect(
          imu.every(
            (p) => [
              p.ax,
              p.ay,
              p.az,
              p.wx,
              p.wy,
              p.wz,
            ].every((v) => v != null && v.isFinite),
          ),
          true,
        );
        expect(mag.every((p) => p.hasMag && !p.hasRawImu), true);
        final rows = (await File(
          '$path/imu_pairs.csv',
        ).readAsLines()).skip(1).toList();
        expect(rows.length, imu.length);
        final offsets = rows
            .map((line) => int.parse(line.split(',').last).abs())
            .toList();
        expect(offsets.every((ns) => ns <= 5000000), true);
        double hz(List<ImuData> frames) {
          int ns(ImuData p) => p.gpsWeek! * 604800000000000 + p.gpsTowNanos!;
          for (var i = 1; i < frames.length; i++) {
            expect(ns(frames[i]), greaterThan(ns(frames[i - 1])));
          }
          return (frames.length - 1) *
              1e9 /
              (ns(frames.last) - ns(frames.first));
        }

        final imuRate = hz(imu);
        final magRate = hz(mag);
        expect(imuRate, inInclusiveRange(70, 120));
        final maximum = ((state['sensors'] as Map)['mag']['maxHz'] as num)
            .toDouble();
        expect(magRate, lessThanOrEqualTo(maximum * 1.1));
        binding.reportData = {
          'session': path,
          'imuFrames': imu.length,
          'magFrames': mag.length,
          'imuHz': imuRate,
          'magHz': magRate,
          'magMaxHz': maximum,
          'maxPairSkewNs': offsets.reduce((a, b) => a > b ? a : b),
          'unpairedSamples': state['unpairedImuSamples'],
          'pauseKeepsRecording': true,
        };
        expect(tester.takeException(), isNull);
      } finally {
        if (startedByTest && (await status())['mode'] != 'idle') {
          await PhoneCaptureService.channel.invokeMethod<void>('stop');
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
