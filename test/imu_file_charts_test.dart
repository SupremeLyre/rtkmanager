import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_file_charts.dart';
import 'package:rtkmanager/imu_file_data.dart';

ImuFileDataset _dataset({bool navigation = true}) {
  final points = List.generate(
    4501,
    (i) => ImuFilePoint(
      time: i / 100,
      values: [math.sin(i / 20), i == 0 ? null : 0, 1],
    ),
  );
  return ImuFileDataset(
    sourcePath: '/recording.csv',
    frameCount: points.length,
    timeBasis: 'GPS 时间',
    xAxisLabel: '相对时间 / s',
    start: 0,
    end: 45,
    series: {
      ImuFileVector.acceleration: points,
      ImuFileVector.gyroscope: points,
      ImuFileVector.magnetic: points,
      if (navigation) ImuFileVector.attitude: points,
      if (navigation) ImuFileVector.velocity: points,
    },
  );
}

Future<void> _pumpCharts(
  WidgetTester tester,
  ImuFileDataset dataset, {
  Size size = const Size(1400, 900),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ImuFileCharts(dataset: dataset),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'trace retains endpoints and extrema with a pixel bounded draw count',
    () {
      final points = List.generate(
        100001,
        (i) => ImuFilePoint(
          time: i / 100,
          values: [i == 34567 ? 999 : math.sin(i / 15), null, 0],
        ),
      );
      final trace = ImuFileTrace.fromPoints(
        points: points,
        axis: 0,
        start: 0,
        end: 1000,
        pixelWidth: 300,
      );
      final drawn = trace.segments.expand((segment) => segment).toList();
      expect(drawn.first.dx, 0);
      expect(drawn.last.dx, 1000);
      expect(drawn.map((point) => point.dy), contains(999));
      expect(drawn.length, lessThanOrEqualTo(4 * 301));
    },
  );

  test('missing axis values, resets and yaw wraps split traces', () {
    final trace = ImuFileTrace.fromPoints(
      points: [
        ImuFilePoint(time: 0, values: [0, 0, 178]),
        ImuFilePoint(time: 1, values: [1, null, 179]),
        ImuFilePoint(time: 2, values: [2, 2, -179]),
        ImuFilePoint(time: 3, values: [3, 3, -178], breakBefore: true),
        ImuFilePoint(time: 4, values: [4, 4, -177]),
      ],
      axis: 2,
      start: 0,
      end: 4,
      pixelWidth: 400,
      wrapDegrees: true,
    );
    expect(trace.segments.map((s) => s.map((p) => p.dx).toList()), [
      [0.0, 1.0],
      [2.0],
      [3.0, 4.0],
    ]);
    final partial = ImuFileTrace.fromPoints(
      points: [
        ImuFilePoint(time: 0, values: [0, 0]),
        ImuFilePoint(time: 1, values: [0, null]),
        ImuFilePoint(time: 2, values: [0, 2]),
        ImuFilePoint(time: 3, values: [0, double.nan]),
        ImuFilePoint(time: 4, values: [0, 4]),
      ],
      axis: 1,
      start: 0,
      end: 4,
      pixelWidth: 400,
    );
    expect(partial.segments.map((s) => s.length), [1, 1, 1]);
  });

  test('dense missing data remains disconnected and bounded', () {
    final trace = ImuFileTrace.fromPoints(
      points: List.generate(
        100000,
        (i) => ImuFilePoint(
          time: i / 1000,
          values: [i.isEven ? i.toDouble() : null],
        ),
      ),
      axis: 0,
      start: 0,
      end: 100,
      pixelWidth: 100,
    );
    expect(trace.segments.every((segment) => segment.length == 1), isTrue);
    expect(trace.segments.length, lessThanOrEqualTo(404));
  });

  test('decimated missing-axis markers break only the affected trace', () {
    final points = [
      ImuFilePoint(time: 0, values: [0, 0, 0]),
      ImuFilePoint(time: 1, values: [1, 1, 1]),
      ImuFilePoint(
        time: 2,
        values: [2, 2, 2],
        axisBreaks: [true, false, false],
      ),
      ImuFilePoint(time: 3, values: [3, 3, 3]),
    ];
    ImuFileTrace trace(int axis) => ImuFileTrace.fromPoints(
      points: points,
      axis: axis,
      start: 0,
      end: 3,
      pixelWidth: 300,
    );
    expect(trace(0).segments.map((segment) => segment.length), [2, 2]);
    expect(trace(1).segments.single.length, 4);
  });

  test(
    'overlapping clock-reset intervals cannot form false vertical lines',
    () {
      final trace = ImuFileTrace.fromPoints(
        points: [
          ImuFilePoint(time: 0, values: [0]),
          ImuFilePoint(time: 1, values: [1]),
          ImuFilePoint(time: 2, values: [2]),
          ImuFilePoint(time: 1, values: [100], breakBefore: true),
          ImuFilePoint(time: 2, values: [101]),
          ImuFilePoint(time: 3, values: [102]),
        ],
        axis: 0,
        start: 0,
        end: 3,
        pixelWidth: 300,
      );
      expect(
        trace.segments.every(
          (segment) =>
              segment.length < 2 ||
              segment.every((sample) => sample.dy < 50) ||
              segment.every((sample) => sample.dy > 50),
        ),
        isTrue,
      );
    },
  );

  test('inspection windows retain original early and late samples', () {
    final points = _dataset().series[ImuFileVector.acceleration]!;
    for (final (start, end) in [(0.0, 1.0), (44.0, 45.0)]) {
      final trace = ImuFileTrace.fromPoints(
        points: points,
        axis: 0,
        start: start,
        end: end,
        pixelWidth: 300,
      );
      expect(trace.segments.first.first.dx, start);
      expect(trace.segments.last.last.dx, end);
      expect(
        trace.segments
            .expand((segment) => segment)
            .every((sample) => sample.dx >= start && sample.dx <= end),
        isTrue,
      );
    }
  });

  testWidgets(
    'full 100 Hz file and its earliest and latest ranges are available',
    (tester) async {
      await _pumpCharts(tester, _dataset());
      var slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      expect(slider.min, 0);
      expect(slider.max, 45);
      expect(slider.values, const RangeValues(0, 45));
      slider.onChanged!(const RangeValues(0, 1));
      await tester.pumpAndSettle();
      expect(find.text('显示范围：0.000 – 1.000 s'), findsOneWidget);
      slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
      slider.onChanged!(const RangeValues(44, 45));
      await tester.pumpAndSettle();
      expect(find.text('显示范围：44.000 – 45.000 s'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('imu-file-full-range')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<RangeSlider>(find.byType(RangeSlider)).values,
        const RangeValues(0, 45),
      );
      expect(find.text('加速度 · g'), findsOneWidget);
      expect(find.text('角速度 · °/s'), findsOneWidget);
      expect(find.text('磁场 · µT'), findsOneWidget);
      expect(find.text('姿态时序 · °'), findsOneWidget);
      expect(find.text('速度时序 · m/s'), findsOneWidget);
      expect(find.text('相对时间 / s'), findsNWidgets(5));
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, scale) in [
    (const Size(320, 640), 2.0),
    (const Size(900, 700), 1.0),
    (const Size(1500, 900), 1.0),
  ]) {
    testWidgets('raw and navigation charts fit $size at text scale $scale', (
      tester,
    ) async {
      await _pumpCharts(tester, _dataset(), size: size, textScale: scale);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('速度时序 · m/s'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final acceleration = tester.getTopLeft(
        find.byKey(const ValueKey('imu-file-chart-acceleration')),
      );
      final gyroscope = tester.getTopLeft(
        find.byKey(const ValueKey('imu-file-chart-gyroscope')),
      );
      if (size.width >= 900 && scale == 1) {
        expect(acceleration.dy, gyroscope.dy);
        expect(gyroscope.dx, greaterThan(acceleration.dx));
      } else {
        expect(gyroscope.dy, greaterThan(acceleration.dy));
      }
    });
  }

  testWidgets('single sample zero values and frame index need no slider', (
    tester,
  ) async {
    final dataset = ImuFileDataset(
      sourcePath: '/sample.csv',
      frameCount: 1,
      timeBasis: '帧序号',
      xAxisLabel: '帧序号',
      start: 0,
      end: 0,
      series: {
        ImuFileVector.acceleration: [
          ImuFilePoint(time: 0, values: [0, null, 0]),
        ],
      },
    );
    await _pumpCharts(
      tester,
      dataset,
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(find.byType(RangeSlider), findsNothing);
    expect(find.text('帧序号'), findsOneWidget);
    expect(find.text('姿态时序 · °'), findsNothing);
    expect(tester.takeException(), isNull);
    final trace = ImuFileTrace.fromPoints(
      points: dataset.series[ImuFileVector.acceleration]!,
      axis: 0,
      start: 0,
      end: 0,
      pixelWidth: 100,
    );
    expect(trace.segments.single.single, Offset.zero);
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.descendant(
        of: find.byKey(const ValueKey('imu-file-chart-acceleration')),
        matching: find.byType(RepaintBoundary),
      ),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = pixels!.buffer.asUint8List();
      var dotPixels = 0;
      final color = Colors.teal.shade800;
      for (var i = 0; i < bytes.length; i += 4) {
        if (bytes[i] == (color.r * 255).round() &&
            bytes[i + 1] == (color.g * 255).round() &&
            bytes[i + 2] == (color.b * 255).round()) {
          dotPixels++;
        }
      }
      image.dispose();
      expect(
        dotPixels,
        greaterThan(2),
        reason: 'A single zero sample is visible',
      );
    });
  });
}
