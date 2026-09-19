import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PhoneCaptureService extends ChangeNotifier {
  static const channel = MethodChannel('rtkmanager/phone_capture');
  static const events = EventChannel('rtkmanager/phone_capture_events');
  Map<String, dynamic> state = {'mode': 'idle'};
  String? error;
  bool busy = false;
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;

  bool get recording => state['mode'] == 'recording';
  bool get probing => state['mode'] == 'probing';
  bool get timeReady => state['timeReady'] == true;
  bool available(String key) =>
      (state['sensors'] as Map?)?[key]?['available'] == true;
  String detail(String key) =>
      (state['sensors'] as Map?)?[key]?['detail'] as String? ?? '尚未检测';

  void listen() {
    _subscription ??= events.receiveBroadcastStream().listen(
      (value) {
        if (_disposed) return;
        state = Map<String, dynamic>.from(value as Map);
        notifyListeners();
      },
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
    super.dispose();
  }
}
