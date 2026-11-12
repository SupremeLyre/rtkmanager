import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rtkmanager/accuracy_chart.dart';
import 'package:rtkmanager/accuracy_controller.dart';
import 'package:rtkmanager/accuracy_evaluation.dart';
import 'package:rtkmanager/accuracy_page.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/mobile_ui.dart';
import 'package:rtkmanager/position_data.dart';
import 'package:rtkmanager/truth_data.dart';

final _start = DateTime.utc(2026, 10, 29, 1);

List<PositionHistoryPoint> _points({
  String sourcePath = r'C:\survey\imu.bin',
}) => [
  for (var second = 0; second < 3; second++)
    PositionHistoryPoint(
      location: const LatLng(30.01, 114.01),
      status: 4,
      type: PointType.imu,
      isImu: true,
      sourcePath: sourcePath,
      wgs84Latitude: 30 + second * .000001,
      wgs84Longitude: 114,
      ellipsoidHeight: 20,
      velocityEast: 1,
      velocityNorth: 2,
      velocityUp: 3,
      utcDateTime: _start.add(Duration(seconds: second)),
      imuData: ImuData()
        ..gnssState = 4
        ..fusionState = 4
        ..roll = 1
        ..pitch = 2
        ..yaw = 3,
    ),
];

TruthDataset _truth() => TruthDataset(
  sourcePath: r'C:\survey\truth.pos',
  samples: [
    for (var second = 0; second < 3; second++)
      TruthSample(
        utcTime: _start.add(Duration(seconds: second)),
        latitude: 30,
        longitude: 114,
        height: 20,
        velocityEast: 0,
        velocityNorth: 0,
        velocityUp: 0,
        roll: 0,
        pitch: 0,
        heading: 0,
      ),
  ],
);

(List<PositionHistoryPoint>, TruthDataset) _previewData() {
  final points = <PositionHistoryPoint>[];
  final truth = <TruthSample>[];
  for (var i = 0; i < 120; i++) {
    final seconds = i.toDouble();
    final travel = math.max(0.0, seconds - 20);
    final time = _start.add(Duration(seconds: i));
    final latitude = 30.52 + travel * .000006;
    final longitude = 114.35 + travel * .000011;
    final height = 25 + .02 * math.sin(seconds / 10);
    final eastVelocity = travel == 0 ? 0.0 : 1.15 + .15 * math.sin(travel / 15);
    final northVelocity = travel == 0 ? 0.0 : .65 + .08 * math.cos(travel / 20);
    final upVelocity = travel == 0 ? 0.0 : .02 * math.sin(travel / 12);
    final roll = .3 * math.sin(seconds / 30);
    final pitch = .5 * math.cos(seconds / 34);
    final heading = 62 + .08 * travel;
    final eastError =
        .18 +
        .018 * math.sin(seconds * .48) +
        .035 * math.sin(travel / 8) +
        .0004 * travel;
    final northError =
        -.12 + .022 * math.cos(seconds * .36) + .018 * math.sin(travel / 13);
    final upError =
        .32 + .045 * math.sin(seconds * .21) + .02 * math.cos(seconds * .5);
    truth.add(
      TruthSample(
        utcTime: time,
        latitude: latitude,
        longitude: longitude,
        height: height,
        velocityEast: eastVelocity,
        velocityNorth: northVelocity,
        velocityUp: upVelocity,
        roll: roll,
        pitch: pitch,
        heading: heading,
      ),
    );
    final solutionLatitude = latitude + northError / 111319.49;
    final solutionLongitude =
        longitude +
        eastError / (111319.49 * math.cos(latitude * math.pi / 180));
    points.add(
      PositionHistoryPoint(
        location: LatLng(solutionLatitude, solutionLongitude),
        status: 4,
        type: PointType.imu,
        isImu: true,
        sourcePath:
            r'D:\FLR\whusgg_2023\PPP\dataset\20261029\imu\trajectory.bin',
        wgs84Latitude: solutionLatitude,
        wgs84Longitude: solutionLongitude,
        ellipsoidHeight: height + upError,
        utcDateTime: time,
        velocityEast: eastVelocity + .025 + .008 * math.sin(seconds / 7),
        velocityNorth: northVelocity - .016 + .006 * math.cos(seconds / 9),
        velocityUp: upVelocity + .01 + .004 * math.sin(seconds / 5),
        imuData: ImuData()
          ..gnssState = 4
          ..fusionState = 4
          ..roll = roll + .35 + .08 * math.sin(seconds / 13)
          ..pitch = pitch - .2 + .06 * math.cos(seconds / 17)
          ..yaw =
              heading +
              1.1 +
              .25 * math.sin(seconds / 18) +
              .06 * math.cos(seconds / 3),
      ),
    );
  }
  return (
    points,
    TruthDataset(
      sourcePath:
          r'D:\FLR\whusgg_2023\PPP\dataset\20261029\truth\truth_20261029.pos',
      samples: truth,
    ),
  );
}

Future<void> _pumpPage(
  WidgetTester tester,
  AccuracyController controller, {
  Size size = const Size(1100, 820),
  double scale = 1,
  Brightness brightness = Brightness.light,
  GlobalKey? previewKey,
  VoidCallback? onShowPositioning,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: mobileTheme(
        ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: brightness,
          ),
          useMaterial3: true,
          fontFamily: 'SourceHanSansHWSC',
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: RepaintBoundary(
        key: previewKey,
        child: AccuracyPage(
          controller: controller,
          mobileLayout: size.width < 600,
          onShowPositioning: onShowPositioning,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  var target = find.byKey(ValueKey(key));
  if (tester.widget(target) is ExpansionTile) {
    target = find.descendant(of: target, matching: find.byType(ListTile)).first;
  }
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _evaluatePage(
  WidgetTester tester,
  AccuracyController controller,
) async {
  final evaluate = find.byKey(const ValueKey('accuracy-evaluate'));
  await tester.ensureVisible(evaluate);
  await tester.runAsync(() async {
    await tester.tap(evaluate);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (controller.busy && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

Future<void> _capturePreview(GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final output = File('${Directory.current.path}/build/ui-previews/$name.png');
  await output.parent.create(recursive: true);
  await output.writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
}

String? _axisCell(WidgetTester tester, String axis, int column) {
  final table = tester.widget<DataTable>(find.byType(DataTable));
  final row = table.rows.firstWhere(
    (row) => (row.cells.first.child as Text).data == axis,
  );
  return (row.cells[column].child as Text).data;
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'SourceHanSansHWSC',
    )..addFont(rootBundle.load('fonts/SourceHanSansHWSC-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test(
    'controller restores original point identity after isolate evaluation',
    () async {
      final points = _points();
      final controller = AccuracyController()
        ..setPoints(points)
        ..setTruthDataset(_truth());
      addTearDown(controller.dispose);
      await controller.evaluate(
        options: const EvaluationOptions(calibrate: false),
      );
      expect(controller.error, isNull);
      expect(controller.evaluation!.records, hasLength(3));
      for (final record in controller.evaluation!.records) {
        expect(identical(record.point, points[record.pointIndex]), isTrue);
      }
      for (final record in controller.evaluation!.layers.single.records) {
        expect(identical(record.point, points[record.pointIndex]), isTrue);
      }
      controller.selectPoint(points[2]);
      expect(controller.selectedError!.point, same(points[2]));
      expect(
        controller.selectedError!.utcTime,
        _start.add(const Duration(seconds: 2)),
      );
      expect(controller.options.calibrate, isFalse);
      controller.setPoints(points.take(2).toList());
      expect(controller.evaluation, isNull);
      expect(controller.selectedError, isNull);
      expect(controller.truth, isNotNull);
      controller.clearTruth();
      expect(controller.truth, isNull);
    },
  );

  test(
    'removing a source preserves other calibration and rebases its records',
    () async {
      const firstSource = r'C:\survey\first.bin';
      const secondSource = r'C:\survey\second.bin';
      final first = _points(sourcePath: firstSource);
      final second = _points(sourcePath: secondSource);
      PositionHistoryPoint unmatched(
        String source,
        int seconds, {
        bool invalid = false,
      }) => PositionHistoryPoint(
        location: const LatLng(30, 114),
        status: 4,
        type: PointType.imu,
        sourcePath: source,
        utcDateTime: _start.add(Duration(seconds: seconds)),
        wgs84Latitude: invalid ? null : 30,
        wgs84Longitude: invalid ? null : 114,
      );
      final missingCoordinates = unmatched(secondSource, 0, invalid: true);
      final outsideTruth = unmatched(secondSource, 20);
      final points = [
        first[0],
        unmatched(firstSource, 10),
        missingCoordinates,
        second[0],
        first[1],
        second[1],
        outsideTruth,
        first[2],
        second[2],
      ];
      final truth = _truth();
      const options = EvaluationOptions(
        stableRtkMinDurationSeconds: 0,
        stablePositionThresholdMeters: .5,
      );
      final controller = AccuracyController()
        ..setPoints(points)
        ..setTruthDataset(truth);
      addTearDown(controller.dispose);
      await controller.evaluate(options: options);
      expect(controller.error, isNull);
      expect(controller.evaluation!.unmatchedCount, 3);
      final retainedLayer = controller.evaluation!.layers.firstWhere(
        (layer) => layer.sourcePath == secondSource,
      );
      expect(retainedLayer.calibration.applied, isTrue);
      controller.selectPoint(first[1]);
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.removeSource(firstSource);
      expect(notifications, 1);
      expect(controller.points, [
        missingCoordinates,
        second[0],
        second[1],
        outsideTruth,
        second[2],
      ]);
      expect(controller.truth, same(truth));
      expect(controller.selectedPoint, isNull);
      expect(controller.selectedError, isNull);
      expect(controller.options, same(options));
      final evaluation = controller.evaluation!;
      expect(evaluation.layers, hasLength(1));
      expect(evaluation.layers.single.sourcePath, secondSource);
      expect(
        evaluation.layers.single.calibration,
        same(retainedLayer.calibration),
      );
      expect(
        evaluation.layers.single.statistics['position'],
        same(retainedLayer.statistics['position']),
      );
      expect(evaluation.records.map((record) => record.pointIndex), [1, 2, 4]);
      for (final record in evaluation.records) {
        expect(record.point, same(controller.points[record.pointIndex]));
        expect(evaluation.layers.single.records, contains(same(record)));
      }
      expect(evaluation.unmatchedCount, 2);
      expect(evaluation.unmatchedPointReasons.keys.toList()..sort(), [0, 3]);
      expect(evaluation.unmatchedReasons, {
        '缺少有效的原始 WGS-84 经纬度': 1,
        '超出真值时间范围或真值间隔过大': 1,
      });
      controller.selectPoint(second[1]);
      expect(controller.selectedError!.pointIndex, 2);

      notifications = 0;
      final remainingPoints = controller.points;
      controller.removeSource('not-imported.bin');
      expect(notifications, 0);
      expect(controller.points, same(remainingPoints));
      expect(controller.evaluation, same(evaluation));

      controller.removeSource(truth.sourcePath);
      expect(notifications, 1);
      expect(controller.truth, isNull);
      expect(controller.evaluation, isNull);
      expect(controller.points, remainingPoints);
      expect(controller.selectedPoint, same(second[1]));
      expect(controller.selectedError, isNull);
    },
  );

  test(
    'removing a source prevents an in-flight evaluation restoring it',
    () async {
      const firstSource = 'first.bin';
      const secondSource = 'second.bin';
      final second = _points(sourcePath: secondSource);
      final controller = AccuracyController()
        ..setPoints([..._points(sourcePath: firstSource), ...second])
        ..setTruthDataset(_truth());
      addTearDown(controller.dispose);
      const options = EvaluationOptions(
        stableRtkMinDurationSeconds: 0,
        stablePositionThresholdMeters: .5,
      );
      await controller.evaluate(options: options);
      final retainedCalibration =
          controller.evaluation!.layers.last.calibration;
      final pending = controller.evaluate(
        options: const EvaluationOptions(calibrate: false),
      );
      expect(controller.busy, isTrue);
      controller.removeSource(firstSource);
      await pending;
      expect(controller.busy, isFalse);
      expect(controller.error, isNull);
      expect(controller.points, second);
      expect(controller.evaluation!.layers, hasLength(1));
      expect(
        controller.evaluation!.layers.single.calibration,
        same(retainedCalibration),
      );
      expect(controller.options, same(options));
      expect(
        controller.evaluation!.records.map((record) => record.pointIndex),
        [0, 1, 2],
      );
    },
  );

  test('removing truth prevents an in-flight import restoring it', () async {
    final directory = Directory.systemTemp.createTempSync(
      'accuracy_remove_truth_',
    );
    final file = File('${directory.path}/truth.csv')
      ..writeAsStringSync(
        'UTC,Latitude,Longitude\n2026-10-29T01:00:00Z,30,114\n',
      );
    final points = _points();
    final controller = AccuracyController()
      ..setPoints(points)
      ..setTruthDataset(
        TruthDataset(sourcePath: file.path, samples: _truth().samples),
      );
    addTearDown(() {
      controller.dispose();
      directory.deleteSync(recursive: true);
    });
    final pending = controller.importTruth(file.path);
    expect(controller.busy, isTrue);
    controller.removeSource(file.path);
    await pending;
    expect(controller.busy, isFalse);
    expect(controller.error, isNull);
    expect(controller.truth, isNull);
    expect(controller.evaluation, isNull);
    expect(controller.points, points);
  });

  for (final (size, scale, brightness) in [
    (const Size(1100, 820), 1.0, Brightness.light),
    (const Size(375, 812), 3.0, Brightness.dark),
    (const Size(720, 375), 1.3, Brightness.light),
  ]) {
    testWidgets(
      'compact accuracy view links charts and epochs at $size / $scale',
      (tester) async {
        final points = _points();
        final controller = AccuracyController()
          ..setPoints(points)
          ..setTruthDataset(_truth());
        addTearDown(controller.dispose);
        await tester.runAsync(() => controller.evaluate());
        expect(controller.error, isNull);
        var showMap = false;
        final previewKey = GlobalKey();
        await _pumpPage(
          tester,
          controller,
          size: size,
          scale: scale,
          brightness: brightness,
          previewKey: previewKey,
          onShowPositioning: () => showMap = true,
        );
        expect(find.text('精度评定'), findsOneWidget);
        expect(find.byType(AccuracyTimeChart), findsOneWidget);
        expect(
          tester.widget<AccuracyTimeChart>(find.byType(AccuracyTimeChart)).kind,
          AccuracyChartKind.position,
        );
        for (final kind in AccuracyChartKind.values) {
          expect(
            find.byKey(ValueKey('accuracy-summary-${kind.name}')),
            findsOneWidget,
          );
        }
        expect(find.byType(DataTable), findsNothing);
        expect(find.text(r'C:\survey\truth.pos'), findsNothing);
        expect(
          find.byKey(const ValueKey('accuracy-calibration-start')),
          findsNothing,
        );
        expect(find.text('此静止区间一次估计位置、速度系统差，全部历元共用。'), findsNothing);
        expect(find.text('水平姿态已就绪，航向尚未就绪，本历元不计航向 RMSE。'), findsNothing);
        if (size.width == 375) {
          await tester.runAsync(
            () => _capturePreview(previewKey, 'accuracy-accessibility'),
          );
        }

        await _tapKey(tester, 'accuracy-data-details');
        expect(find.text(r'C:\survey\truth.pos'), findsOneWidget);
        await _tapKey(tester, 'accuracy-data-details');
        expect(find.text(r'C:\survey\truth.pos'), findsNothing);
        await _tapKey(tester, 'accuracy-summary-velocity');
        expect(
          tester.widget<AccuracyTimeChart>(find.byType(AccuracyTimeChart)).kind,
          AccuracyChartKind.velocity,
        );
        for (final kind in [
          AccuracyChartKind.velocity,
          AccuracyChartKind.attitude,
        ]) {
          await _tapKey(tester, 'accuracy-kind-${kind.name}');
          expect(find.byType(AccuracyTimeChart), findsOneWidget);
          expect(
            tester
                .widget<AccuracyTimeChart>(find.byType(AccuracyTimeChart))
                .kind,
            kind,
          );
          expect(
            find.byKey(ValueKey('accuracy-chart-${kind.name}')),
            findsOneWidget,
          );
        }
        await _tapKey(tester, 'accuracy-kind-position');
        expect(
          tester
              .widget<AccuracyTimeChart>(find.byType(AccuracyTimeChart))
              .corrected,
          isTrue,
        );
        await _tapKey(tester, 'accuracy-corrected-toggle');
        expect(
          tester
              .widget<AccuracyTimeChart>(find.byType(AccuracyTimeChart))
              .corrected,
          isFalse,
        );
        await _tapKey(tester, 'accuracy-corrected-toggle');

        final calibration = controller.evaluation!.layers.single.calibration;
        expect(calibration.positionCount, 0);
        expect(calibration.positionOffset.x, isNull);
        expect(calibration.attitudeCount, 1);
        expect(
          calibration.attitudeReferenceTime,
          _start.add(const Duration(seconds: 2)),
        );
        await _tapKey(tester, 'accuracy-calibration-details');
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('accuracy-attitude-reference-time')),
              )
              .data,
          accuracyUtcLabel(calibration.attitudeReferenceTime!),
        );
        expect(find.text(calibration.unavailableReason!), findsOneWidget);
        await _tapKey(tester, 'accuracy-calibration-details');

        await tester.ensureVisible(find.byTooltip('下一误差历元'));
        await tester.tap(find.byTooltip('下一误差历元'));
        await tester.pump();
        expect(controller.selectedPoint, same(points[1]));
        expect(
          tester
              .widget<Slider>(
                find.byKey(const ValueKey('accuracy-epoch-slider')),
              )
              .value,
          1,
        );
        await tester.ensureVisible(find.byTooltip('上一误差历元'));
        await tester.tap(find.byTooltip('上一误差历元'));
        await tester.pump();
        expect(controller.selectedPoint, same(points.first));
        controller.selectPoint(points[2]);
        await tester.pump();
        expect(
          tester
              .widget<Slider>(
                find.byKey(const ValueKey('accuracy-epoch-slider')),
              )
              .value,
          2,
        );
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('accuracy-selected-time')),
              )
              .data,
          accuracyUtcLabel(_start.add(const Duration(seconds: 2))),
        );
        final chart = find.byKey(const ValueKey('accuracy-chart-position'));
        await tester.ensureVisible(chart);
        await tester.tapAt(tester.getTopLeft(chart) + const Offset(8, 60));
        await tester.pump();
        expect(controller.selectedPoint, same(points.first));
        await _tapKey(tester, 'accuracy-show-map');
        expect(showMap, isTrue);
        expect(controller.locateRevision, 1);
        controller.selectPoint(
          PositionHistoryPoint(
            location: const LatLng(30, 114),
            status: 4,
            type: PointType.imu,
            sourcePath: points.first.sourcePath,
            utcDateTime: _start.add(const Duration(seconds: 30)),
          ),
        );
        await tester.pump();
        expect(find.textContaining('未匹配真值'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('accuracy-selected-time')),
          findsNothing,
        );
        await tester.ensureVisible(find.text('选择首个匹配历元'));
        await tester.tap(find.text('选择首个匹配历元'));
        await tester.pump();
        expect(controller.selectedPoint, same(points.first));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final (size, name) in [
    (const Size(1100, 820), 'accuracy-desktop'),
    (const Size(375, 812), 'accuracy-mobile'),
  ]) {
    testWidgets('accuracy preview $name uses evaluated trajectory', (
      tester,
    ) async {
      final (points, truth) = _previewData();
      final controller = AccuracyController()
        ..setPoints(points)
        ..setTruthDataset(truth);
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.evaluate());
      expect(controller.error, isNull);
      expect(controller.evaluation!.records, hasLength(120));
      expect(
        controller.evaluation!.layers.single.calibration.positionCount,
        greaterThan(10),
      );
      controller.selectPoint(points[65]);
      final previewKey = GlobalKey();
      await _pumpPage(
        tester,
        controller,
        size: size,
        previewKey: previewKey,
        onShowPositioning: () {},
      );
      expect(find.byType(AccuracyTimeChart), findsOneWidget);
      expect(find.byType(DataTable), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => _capturePreview(previewKey, name));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('settings sheet validates and configures one fixed calibration', (
    tester,
  ) async {
    final controller = AccuracyController()
      ..setPoints(_points())
      ..setTruthDataset(_truth());
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.evaluate());
    await _pumpPage(tester, controller);
    expect(controller.options.stableRtkMinDurationSeconds, 10);
    expect(controller.options.stableRtkMaxGapSeconds, 2);
    expect(controller.options.stationarySpeedThresholdMps, .1);
    expect(controller.options.stablePositionThresholdMeters, .2);
    final initialCalibration = controller.evaluation!.layers.single.calibration;
    expect(initialCalibration.positionCount, 0);
    expect(initialCalibration.positionOffset.x, isNull);
    expect(initialCalibration.attitudeCount, 1);
    expect(initialCalibration.applied, isTrue);
    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    await _tapKey(tester, 'accuracy-settings');
    expect(
      find.byKey(const ValueKey('accuracy-settings-sheet')),
      findsOneWidget,
    );
    final duration = field('连续静止最短时长（秒）');
    final gap = field('静态解最大间隔（秒）');
    final speed = field('静止速度阈值（m/s）');
    final spread = field('静态位置漂移阈值（m）');
    await tester.ensureVisible(duration);
    await tester.enterText(duration, '-1');
    await _tapKey(tester, 'accuracy-settings-apply');
    expect(find.byKey(const ValueKey('accuracy-settings-sheet')), findsNothing);
    await _evaluatePage(tester, controller);
    expect(controller.error, contains('连续静止最短时长须为非负数'));
    expect(controller.options.stableRtkMinDurationSeconds, 10);

    await _tapKey(tester, 'accuracy-settings');
    await tester.ensureVisible(duration);
    await tester.enterText(duration, '0');
    await tester.ensureVisible(gap);
    await tester.enterText(gap, '1');
    await tester.ensureVisible(speed);
    await tester.enterText(speed, '-0.1');
    await _tapKey(tester, 'accuracy-settings-apply');
    await _evaluatePage(tester, controller);
    expect(controller.error, contains('静止速度阈值须为非负数'));
    await _tapKey(tester, 'accuracy-settings');
    await tester.ensureVisible(speed);
    await tester.enterText(speed, '0.1');
    await tester.ensureVisible(spread);
    await tester.enterText(spread, '0.5');
    await _tapKey(tester, 'accuracy-settings-apply');
    await _evaluatePage(tester, controller);
    expect(controller.error, isNull);
    expect(controller.options.stableRtkMinDurationSeconds, 0);
    expect(controller.options.stableRtkMaxGapSeconds, 1);
    expect(controller.options.stationarySpeedThresholdMps, .1);
    expect(controller.options.stablePositionThresholdMeters, .5);
    final calibration = controller.evaluation!.layers.single.calibration;
    expect(calibration.stableRtkCount, 3);
    expect(calibration.applied, isTrue);
    expect(calibration.intervalStart, _start);
    expect(calibration.intervalEnd, _start.add(const Duration(seconds: 2)));
    expect(
      find.byKey(const ValueKey('accuracy-calibration-start')),
      findsNothing,
    );
    await _tapKey(tester, 'accuracy-calibration-details');
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('accuracy-calibration-start')),
          )
          .data,
      accuracyUtcLabel(_start),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('accuracy-calibration-end')))
          .data,
      contains(accuracyUtcLabel(_start.add(const Duration(seconds: 2)))),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'static PPP calibration keeps a single interval and fixed bias in details',
    (tester) async {
      final points = [
        for (var second = 0; second < 3; second++)
          PositionHistoryPoint(
            location: const LatLng(30, 114),
            status: 4,
            type: PointType.pppsol,
            sourcePath: 'static-ppp.pos',
            wgs84Latitude: 30,
            wgs84Longitude: 114,
            ellipsoidHeight: 20,
            velocityEast: .4,
            velocityNorth: 0,
            velocityUp: 0,
            utcDateTime: _start.add(Duration(seconds: second)),
          ),
      ];
      final controller = AccuracyController()
        ..setPoints(points)
        ..setTruthDataset(_truth());
      addTearDown(controller.dispose);
      await tester.runAsync(
        () => controller.evaluate(
          options: const EvaluationOptions(stableRtkMinDurationSeconds: 0),
        ),
      );
      expect(controller.error, isNull);
      final calibration = controller.evaluation!.layers.single.calibration;
      expect(calibration.applied, isTrue);
      expect(calibration.positionCount, 3);
      expect(calibration.velocityOffset.x, closeTo(.4, 1e-9));
      await _pumpPage(tester, controller);
      expect(find.byType(DataTable), findsNothing);
      expect(
        find.byKey(const ValueKey('accuracy-calibration-start')),
        findsNothing,
      );
      await _tapKey(tester, 'accuracy-calibration-details');
      expect(
        find.byKey(const ValueKey('accuracy-calibration-start')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('accuracy-calibration-end')),
        findsOneWidget,
      );
      await _tapKey(tester, 'accuracy-kind-velocity');
      await _tapKey(tester, 'accuracy-statistics-details');
      expect(find.byType(DataTable), findsOneWidget);
      expect(_axisCell(tester, 'E', 1), '3');
      expect(_axisCell(tester, 'E', 3), '0.0000');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('heading statistics exclude the horizontal-only startup phase', (
    tester,
  ) async {
    final times = List.generate(14, (i) => _start.add(Duration(seconds: i)));
    final points = [
      for (var i = 0; i < times.length; i++)
        PositionHistoryPoint(
          location: const LatLng(30, 114),
          status: 4,
          type: PointType.imu,
          isImu: true,
          sourcePath: r'C:\survey\phased-alignment.bin',
          wgs84Latitude: 30,
          wgs84Longitude: 114,
          ellipsoidHeight: 20,
          utcDateTime: times[i],
          velocityEast: i <= 10 ? 0 : 1,
          velocityNorth: 0,
          velocityUp: 0,
          imuData: ImuData()
            ..gnssState = 4
            ..fusionState = i <= 10 ? 1 : 4
            ..roll = 1
            ..pitch = 2
            ..yaw = i <= 10 ? 0 : 121,
        ),
    ];
    final controller = AccuracyController()
      ..setPoints(points)
      ..setTruthDataset(
        TruthDataset(
          sourcePath: r'C:\survey\truth.pos',
          samples: [
            for (var i = 0; i < times.length; i++)
              TruthSample(
                utcTime: times[i],
                latitude: 30,
                longitude: 114,
                height: 20,
                velocityEast: i <= 10 ? 0 : 1,
                velocityNorth: 0,
                velocityUp: 0,
                roll: 0,
                pitch: 0,
                heading: 120,
              ),
          ],
        ),
      );
    addTearDown(controller.dispose);
    await tester.runAsync(() => controller.evaluate());
    expect(controller.error, isNull);
    final layer = controller.evaluation!.layers.single;
    expect(layer.calibration.tiltCount, 1);
    expect(layer.calibration.headingCount, 1);
    expect(layer.calibration.attitudeReferenceTime, times.last);
    expect(layer.statistics['attitude']!.z.count, 3);
    expect(layer.statistics['attitude']!.z.rmse, closeTo(0, 1e-9));
    await _pumpPage(tester, controller);
    await _tapKey(tester, 'accuracy-kind-attitude');
    expect(
      find.byKey(const ValueKey('accuracy-attitude-readiness')),
      findsOneWidget,
    );
    expect(find.text('航向对准中'), findsOneWidget);
    expect(find.text('水平姿态已就绪，航向尚未就绪，本历元不计航向 RMSE。'), findsNothing);
    await _tapKey(tester, 'accuracy-calibration-details');
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('accuracy-attitude-reference-time')),
          )
          .data,
      accuracyUtcLabel(times.last),
    );
    await _tapKey(tester, 'accuracy-statistics-details');
    expect(find.byType(DataTable), findsOneWidget);
    expect(_axisCell(tester, 'Heading', 1), '3');
    expect(_axisCell(tester, 'Heading', 3), '0.0000');
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('accuracy-selected-error-z')))
          .data,
      contains('—'),
    );
    controller.selectPoint(points.last);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('accuracy-attitude-readiness')),
      findsNothing,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('accuracy-selected-error-z')))
          .data,
      contains('0.0000'),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'last valid FIX supplies one attitude correction while INS errors remain',
    (tester) async {
      final times = List.generate(24, (i) => _start.add(Duration(seconds: i)));
      final points = [
        for (var i = 0; i < times.length; i++)
          PositionHistoryPoint(
            location: const LatLng(30, 114),
            status: i == 23 ? 6 : 4,
            type: PointType.imu,
            isImu: true,
            sourcePath: r'C:\survey\heading-alignment.bin',
            wgs84Latitude: 30,
            wgs84Longitude: 114,
            ellipsoidHeight: 20,
            utcDateTime: times[i],
            velocityEast: i <= 10 ? 0 : 1,
            velocityNorth: 0,
            velocityUp: 0,
            imuData: ImuData()
              ..gnssState = i == 23 ? 0 : 4
              ..fusionState = i <= 10
                  ? 1
                  : i == 23
                  ? 5
                  : 4
              ..roll = 1
              ..pitch = 2
              ..yaw = i <= 10
                  ? 0
                  : i == 23
                  ? 124
                  : 121,
          ),
      ];
      final controller = AccuracyController()
        ..setPoints(points)
        ..setTruthDataset(
          TruthDataset(
            sourcePath: r'C:\survey\truth.pos',
            samples: [
              for (var i = 0; i < times.length; i++)
                TruthSample(
                  utcTime: times[i],
                  latitude: 30,
                  longitude: 114,
                  height: 20,
                  velocityEast: i <= 10 ? 0 : 1,
                  velocityNorth: 0,
                  velocityUp: 0,
                  roll: 0,
                  pitch: 0,
                  heading: 120,
                ),
            ],
          ),
        );
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.evaluate());
      expect(controller.error, isNull);
      final layer = controller.evaluation!.layers.single;
      expect(layer.calibration.attitudeReferenceTime, times[22]);
      expect(layer.calibration.headingBias, closeTo(1, 1e-9));
      expect(layer.calibration.headingBiasCount, 1);
      expect(layer.calibration.tiltCount, 1);
      expect(layer.rawStatistics['attitude']!.z.count, 13);
      expect(
        layer.rawStatistics['attitude']!.z.rmse,
        closeTo(math.sqrt(28 / 13), 1e-9),
      );
      expect(layer.statistics['attitude']!.z.count, 13);
      expect(
        layer.statistics['attitude']!.z.rmse,
        closeTo(3 / math.sqrt(13), 1e-9),
      );
      expect(layer.records.last.correctedAttitude.z, closeTo(3, 1e-9));
      await _pumpPage(tester, controller);
      await _tapKey(tester, 'accuracy-kind-attitude');
      await _tapKey(tester, 'accuracy-calibration-details');
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('accuracy-attitude-reference-time')),
            )
            .data,
        accuracyUtcLabel(times[22]),
      );
      await _tapKey(tester, 'accuracy-statistics-details');
      expect(_axisCell(tester, 'Heading', 1), '13');
      expect(
        _axisCell(tester, 'Heading', 3),
        (3 / math.sqrt(13)).toStringAsFixed(4),
      );
      controller.selectPoint(points.last);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('accuracy-attitude-readiness')),
        findsNothing,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('accuracy-selected-error-z')),
            )
            .data,
        contains('3.0000'),
      );
      await _tapKey(tester, 'accuracy-corrected-toggle');
      expect(
        _axisCell(tester, 'Heading', 3),
        math.sqrt(28 / 13).toStringAsFixed(4),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('accuracy-selected-error-z')),
            )
            .data,
        contains('4.0000'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'accuracy empty state disables evaluation and keeps setup concise',
    (tester) async {
      final controller = AccuracyController();
      addTearDown(controller.dispose);
      await _pumpPage(tester, controller);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('accuracy-evaluate')),
            )
            .onPressed,
        isNull,
      );
      expect(find.byType(AccuracyTimeChart), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('评定设置'), findsOneWidget);
      expect(find.byTooltip('评定说明'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'truth import previews reordered columns and reveals path on demand',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'accuracy_truth_ui_',
      );
      final file = File('${directory.path}/truth.csv')
        ..writeAsStringSync(
          'Longitude,Week,GPSTime,Latitude,Roll,VEast\n'
          '114.35,2442,351158,30.52,1.5,0.2\n'
          '114.36,2442,351159,30.53,1.6,0.3\n',
        );
      FilePicker.platform = _TruthFilePicker(file.path);
      final controller = AccuracyController();
      addTearDown(() {
        controller.dispose();
        directory.deleteSync(recursive: true);
      });
      await _pumpPage(tester, controller);
      await tester.runAsync(() async {
        await tester.tap(find.text('导入真值'));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (find.text('真值列映射').evaluate().isEmpty &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      expect(find.text('真值列映射'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('确认导入'));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (controller.truth == null && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(controller.error, isNull);
      expect(controller.truth!.sourcePath, file.path);
      expect(controller.truth!.samples, hasLength(2));
      expect(controller.truth!.samples.first.latitude, 30.52);
      expect(controller.truth!.samples.first.longitude, 114.35);
      expect(controller.truth!.samples.first.velocityEast, .2);
      expect(find.text(file.path), findsNothing);
      await _tapKey(tester, 'accuracy-data-details');
      expect(find.text(file.path), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('accuracy-evaluate')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _TruthFilePicker extends FilePicker {
  _TruthFilePicker(this.path);
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
    PlatformFile(path: path, name: 'truth.csv', size: File(path).lengthSync()),
  ]);
}
