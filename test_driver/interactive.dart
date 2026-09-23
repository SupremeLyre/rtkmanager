// Development-only entry point. Production main.dart has no driver extension.
import 'dart:convert';
import 'package:flutter_driver/driver_extension.dart';
import 'package:rtkmanager/main.dart' as app;
import 'package:rtkmanager/phone_capture_service.dart';

Future<void> main() async {
  enableFlutterDriverExtension(
    handler: (request) async {
      if (request == 'captureStatus') {
        return jsonEncode(
          await PhoneCaptureService.channel.invokeMethod<Object?>('status'),
        );
      }
      throw ArgumentError('Unknown inspection request: $request');
    },
  );
  await app.main();
}
