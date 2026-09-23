import 'package:flutter_driver/flutter_driver.dart';

// Read-only inspection for an app launched with test_driver/interactive.dart.
Future<void> main(List<String> args) async {
  final driver = await FlutterDriver.connect(dartVmServiceUrl: args.single);
  try {
    // ignore: avoid_print
    print(await driver.requestData('captureStatus'));
  } finally {
    await driver.close();
  }
}
