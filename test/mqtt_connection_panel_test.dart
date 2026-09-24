import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/app_ui.dart';
import 'package:rtkmanager/mqtt_connection_panel.dart';
import 'package:rtkmanager/mqtt_position_archive.dart';
import 'package:rtkmanager/mqtt_position_service.dart';

void main() {
  for (final (size, scale, dark) in [
    (const Size(375, 812), 1.0, false),
    (const Size(320, 640), 2.0, true),
    (const Size(640, 360), 1.3, false),
    (const Size(1000, 760), 1.0, true),
  ]) {
    testWidgets(
      'MQTT collapsed settings preserve credentials and controls at $size / $scale',
      (tester) async {
        final directory = Directory.systemTemp.createTempSync('mqtt_panel_');
        final service = _PanelService(
          MqttPositionArchive(directory: () async => directory),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            service.dispose();
            await service.archive.close();
            directory.deleteSync(recursive: true);
          });
        });
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var receives = 0, opens = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: mobileTheme(
              ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: MqttConnectionPanel(
                      service: service,
                      onReceive: () => receives++,
                      onOpenLogs: () => opens++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('未连接'), findsOneWidget);
        expect(find.byKey(const ValueKey('mqtt-username')), findsNothing);
        expect(find.text('地图缓存'), findsNothing);
        Future<void> tap(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        Future<void> enter(String key, String text) async {
          final field = find.byKey(ValueKey(key));
          await tester.ensureVisible(field);
          await tester.enterText(field, text);
          await tester.pump();
        }

        await tap(find.text('账号与安全'));
        await enter('mqtt-username', 'test-user');
        await enter('mqtt-password', 'test-password');
        tester.view.viewInsets = const FakeViewPadding(bottom: 160);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('mqtt-password')));
        await tester.pumpAndSettle();
        expect(
          tester.getBottomRight(find.byKey(const ValueKey('mqtt-password'))).dy,
          lessThanOrEqualTo(size.height - 160),
        );
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const ValueKey('mqtt-password')),
              )
              .controller!
              .text,
          'test-password',
        );
        await tap(find.byTooltip('显示密码'));
        expect(find.byTooltip('隐藏密码'), findsOneWidget);
        await tap(find.byType(SwitchListTile));
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('mqtt-port')))
              .controller!
              .text,
          '8883',
        );
        await enter('mqtt-port', '2883');
        await tap(find.byType(SwitchListTile));
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('mqtt-port')))
              .controller!
              .text,
          '2883',
        );
        await tap(find.text('账号与安全'));
        expect(find.byKey(const ValueKey('mqtt-username')), findsNothing);
        await enter('mqtt-topic', 'devices/+/position');
        await tap(find.text('连接并接收'));
        expect(receives, 1);
        expect(service.settings.username, 'test-user');
        expect(service.settings.password, 'test-password');
        expect(service.settings.port, 2883);
        expect(service.settings.tls, isFalse);
        expect(service.settings.topic, 'devices/+/position');
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('mqtt-host')))
              .enabled,
          isFalse,
        );
        expect(find.text('已连接'), findsOneWidget);
        await tap(find.text('接收详情'));
        expect(find.text('地图缓存'), findsOneWidget);
        await tap(find.text('接收日志'));
        expect(opens, 1);
        await tap(find.text('断开连接'));
        expect(
          tester
              .widget<TextFormField>(find.byKey(const ValueKey('mqtt-host')))
              .enabled,
          isTrue,
        );
        service.fail();
        await tester.pumpAndSettle();
        expect(find.text('连接失败，请重试'), findsOneWidget);
        expect(find.text('日志写入失败，请检查存储空间'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}

class _PanelService extends MqttPositionService {
  _PanelService(MqttPositionArchive archive) : super(archive: archive);
  @override
  Future<void> connect(MqttPositionSettings value) async {
    settings = value;
    connection = MqttPositionConnection.connected;
    receivedMessages = 1234567;
    archive.savedRecords = 1234500;
    notifyListeners();
  }

  void fail() {
    connection = MqttPositionConnection.failed;
    error = '连接失败，请重试';
    archive.error = '日志写入失败，请检查存储空间';
    notifyListeners();
  }
}
