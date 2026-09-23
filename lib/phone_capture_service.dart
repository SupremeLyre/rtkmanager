import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'imu_data_parser.dart';

class PhoneCaptureService extends ChangeNotifier {
  static const channel = MethodChannel('rtkmanager/phone_capture');
  static const events = EventChannel('rtkmanager/phone_capture_events');
  Map<String, dynamic> state = {'mode': 'idle'};
  String? error;
  bool busy = false;
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;
  final _imu = StreamController<ImuData>.broadcast();
  final _parser = ImuDataParser();
  Stream<ImuData> get imuDataStream => _imu.stream;

  bool get recording => state['mode'] == 'recording';
  bool get probing => state['mode'] == 'probing';
  bool get timeReady => state['timeReady'] == true;
  bool available(String key) => key == 'imu'
      ? available('accel') && available('gyro')
      : (state['sensors'] as Map?)?[key]?['available'] == true;
  String detail(String key) =>
      (state['sensors'] as Map?)?[key]?['detail'] as String? ??
      (key == 'imu'
          ? '加速度计：${detail('accel')}\n陀螺仪：${detail('gyro')}'
          : '尚未检测');
  double? maxHz(String key) =>
      ((state['sensors'] as Map?)?[key]?['maxHz'] as num?)?.toDouble();
  double rate(String key) =>
      ((state['rates'] as Map?)?[key] as num?)?.toDouble() ?? 0;

  @visibleForTesting
  void acceptEvent(dynamic value) {
    if (_disposed) return;
    final event = Map<String, dynamic>.from(value as Map);
    if (event['type'] == 'samples') {
      for (final frame in event['frames'] as List? ?? []) {
        _parser.parseData(
          List<int>.from(frame as List),
          _imu.add,
          broadcast: false,
        );
      }
      return;
    }
    state = event;
    notifyListeners();
  }

  void listen() {
    _subscription ??= events.receiveBroadcastStream().listen(
      acceptEvent,
      onError: (Object e) {
        if (_disposed) return;
        error = e.toString();
        notifyListeners();
      },
    );
  }

  Future<void> command(String method, [Map<String, dynamic>? args]) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await channel.invokeMethod<dynamic>(method, args);
    } on PlatformException catch (e) {
      error = e.message ?? e.code;
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  static Future<List<Map<String, dynamic>>> sessions() async =>
      (await channel.invokeListMethod<dynamic>('sessions') ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription?.cancel());
    unawaited(_imu.close());
    super.dispose();
  }
}
