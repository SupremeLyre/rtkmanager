import 'package:flutter_test/flutter_test.dart';
import 'package:rtkmanager/imu_data_parser.dart';
import 'package:rtkmanager/imu_history.dart';

ImuData sample(int nanos) => ImuData()
  ..gpsWeek = 2400
  ..gpsTowNanos = nanos
  ..ax = 1
  ..ay = 0
  ..az = -1
  ..wx = 180
  ..wy = 0
  ..wz = 0;

void main() {
  final now = DateTime.utc(2026, 9, 19);
  test('paired six-axis frames keep zero values and hardware timing', () {
    final history = ImuHistory();
    for (var i = 0; i < 100; i++) {
      history.add(sample(i * 10000000), arrivalUs: 100, now: now);
    }
    expect(history.rate(ImuVector.acceleration, now), closeTo(100, 0.001));
    expect(history.rate(ImuVector.gyroscope, now), closeTo(100, 0.001));
    expect(history.points(ImuVector.acceleration, 10).last.values, [1, 0, -1]);
    expect(history.points(ImuVector.magnetic, 10), isEmpty);
    expect(
      history.rate(ImuVector.gyroscope, now.add(const Duration(seconds: 3))),
      0,
    );
  });
  test('bounded memory and clock resets discard incompatible history', () {
    final history = ImuHistory(maxPoints: 20);
    for (var i = 0; i < 100; i++) {
      history.add(sample(i * 100000000), arrivalUs: i, now: now);
    }
    expect(history.points(ImuVector.acceleration, 30), hasLength(20));
    history.add(sample(0), arrivalUs: 0, now: now);
    expect(history.count, 1);
    expect(history.points(ImuVector.acceleration, 30), hasLength(1));
    final noTime = sample(0)
      ..gpsWeek = null
      ..gpsTowNanos = null;
    history.add(noTime, arrivalUs: 200, now: now);
    expect(history.timeBasis, '接收时间');
    expect(history.count, 1);
  });
  test(
    'magnetic frames have independent rates and cannot fabricate IMU axes',
    () {
      final history = ImuHistory();
      for (var i = 0; i < 100; i++) {
        history.add(sample(i * 10000000), arrivalUs: 0, now: now);
        if (i.isEven) {
          history.add(
            ImuData()
              ..gpsWeek = 2400
              ..gpsTowNanos = i * 10000000
              ..mx = 10
              ..my = 20
              ..mz = 30,
            arrivalUs: 0,
            now: now,
          );
        }
      }
      expect(history.points(ImuVector.acceleration, 10), hasLength(100));
      expect(history.points(ImuVector.magnetic, 10), hasLength(50));
      expect(history.rate(ImuVector.magnetic, now), closeTo(50, .001));
      history.add(sample(1000000000)..ax = double.nan, arrivalUs: 0, now: now);
      expect(history.points(ImuVector.acceleration, 10), hasLength(100));
      expect(history.points(ImuVector.gyroscope, 10), hasLength(101));
    },
  );
}
