import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/serial_imu_page.dart';
import 'package:rtkmanager/serial_service.dart';

class _Port extends SerialService {
  _Port(this.name) : super.create();
  final String name;
  final frames = StreamController<ImuData>.broadcast();
  @override
  String get currentPortName => name;
  @override
  Stream<ImuData> get imuDataStream => frames.stream;
}

void main() {
  testWidgets(
    'selects one serial source, resets paused charts and unsubscribes old port',
    (tester) async {
      final a = _Port('COM3');
      final b = _Port('COM4');
      SerialService.connectedServices.value = [a, b];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: SerialImuPage(
            onOpenDrawer: () {},
            onOpenSerial: () {},
            active: true,
          ),
        ),
      );
      a.frames.add(
        ImuData()
          ..ax = 1
          ..ay = 2
          ..az = 3,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.textContaining('已接收 1 帧'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '暂停显示'));
      await tester.pump();
      tester
          .widget<DropdownButtonFormField<SerialService>>(
            find.byType(DropdownButtonFormField<SerialService>),
          )
          .onChanged!(b);
      await tester.pump();
      expect(find.text('串口 · COM4'), findsOneWidget);
      expect(find.textContaining('已接收 0 帧'), findsOneWidget);
      expect(a.frames.hasListener, isFalse);
      b.frames.add(
        ImuData()
          ..wx = 4
          ..wy = 5
          ..wz = 6,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.textContaining('已接收 1 帧'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      SerialService.connectedServices.value = [];
      await a.frames.close();
      await b.frames.close();
      a.dispose();
      b.dispose();
    },
  );
}
