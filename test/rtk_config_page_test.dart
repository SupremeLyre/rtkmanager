import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/rtk_config_page.dart';

void main() {
  testWidgets('RTK form survives denied serial access on a phone', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var scans = 0;
    var drawerOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: RtkConfigPage(
          onOpenDrawer: () => drawerOpened = true,
          listSerialPorts: () {
            scans++;
            throw const SerialPortError('Permission denied', 13);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('NTRIP 连接配置'), findsOneWidget);
    expect(find.text('连接 NTRIP'), findsOneWidget);
    expect(find.textContaining('无法获取串口列表'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'localhost');
    await tester.pump();
    expect(find.text('localhost'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.menu));
    expect(drawerOpened, isTrue);

    await tester.ensureVisible(find.byTooltip('刷新串口列表'));
    await tester.tap(find.byTooltip('刷新串口列表'));
    await tester.pumpAndSettle();
    expect(scans, 2);
    expect(tester.takeException(), isNull);
    expect(find.text('NTRIP 连接配置'), findsOneWidget);

    await tester.ensureVisible(find.text('添加输出串口'));
    await tester.tap(find.text('添加输出串口'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.delete), findsOneWidget);
  });

  testWidgets('RTK serial choices recover after a failed scan', (tester) async {
    var denyAccess = true;
    await tester.pumpWidget(
      MaterialApp(
        home: RtkConfigPage(
          onOpenDrawer: () {},
          listSerialPorts: () {
            if (denyAccess) {
              throw const SerialPortError('Permission denied', 13);
            }
            return ['COM3'];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    denyAccess = false;
    await tester.ensureVisible(find.byTooltip('刷新串口列表'));
    await tester.tap(find.byTooltip('刷新串口列表'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('主串口'));
    await tester.tap(find.text('主串口'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('COM3'), findsOneWidget);
    await tester.tap(find.text('COM3'));
    await tester.pumpAndSettle();
    expect(find.text('COM3'), findsOneWidget);
  });
}
