import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/phone_capture_service.dart';

void main() {
  test(
    'batched native frames reach charts without replacing capture status or broadcasting as serial',
    () async {
      final capture = PhoneCaptureService();
      final frames = <ImuData>[];
      final global = <ImuData>[];
      final sub = capture.imuDataStream.listen(frames.add);
      final serial = ImuDataParser.imuDataStream.listen(global.add);
      capture.acceptEvent({'mode': 'recording', 'timeReady': true});
      capture.acceptEvent({
        'type': 'samples',
        'frames': [
          File('test/fixtures/phone_imu_paired.bin').readAsBytesSync(),
          File(
            'test/fixtures/phone_sensors.bin',
          ).readAsBytesSync().sublist(104),
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(frames, hasLength(2));
      expect(frames.first.ax, 1);
      expect(frames.first.wx, closeTo(180, .00001));
      expect(frames.last.hasMag, isTrue);
      expect(capture.recording, isTrue);
      expect(capture.timeReady, isTrue);
      expect(global, isEmpty);
      await sub.cancel();
      await serial.cancel();
      capture.dispose();
    },
  );
}
