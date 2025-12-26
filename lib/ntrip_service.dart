import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

class NtripService extends ChangeNotifier {
  static final NtripService _instance = NtripService._internal();

  factory NtripService() {
    return _instance;
  }

  NtripService._internal();

  Socket? _socket;
  StreamSubscription? _socketSubscription;
  bool _isConnected = false;
  bool _hasConfig = false;

  final StreamController<Uint8List> _dataStreamController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get dataStream => _dataStreamController.stream;

  final StreamController<String> _logStreamController =
      StreamController<String>.broadcast();
  Stream<String> get logStream => _logStreamController.stream;

  bool get isConnected => _isConnected;
  bool get hasConfig => _hasConfig;

  void setHasConfig(bool value) {
    if (_hasConfig != value) {
      _hasConfig = value;
      notifyListeners();
    }
  }

  void addLog(String message) {
    _logStreamController.add(
      "[${DateTime.now().toString().split('.')[0]}] $message",
    );
  }

  Future<void> connect(
    String ip,
    int port,
    String mountPoint,
    String user,
    String password,
  ) async {
    if (_isConnected) return;

    addLog("正在连接到 $mountPoint ($ip:$port)...");

    try {
      _socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 5),
      );

      String request = _buildNtripRequest(mountPoint, user, password);
      addLog("发送登录请求...");
      _socket!.write(request);

      _socketSubscription = _socket!.listen(
        (data) {
          if (!_isConnected) {
            String response = String.fromCharCodes(data);
            if (response.contains("ICY 200 OK") ||
                response.contains("HTTP/1.0 200 OK") ||
                response.contains("HTTP/1.1 200 OK")) {
              addLog("登录成功 (200 OK)");
              _isConnected = true;
              notifyListeners();
            } else {
              addLog("登录失败，服务器响应:\n$response");
              disconnect();
            }
          } else {
            _dataStreamController.add(data);
            // addLog("收到 RTCM 数据: ${data.length} bytes"); // Too verbose
          }
        },
        onError: (e) {
          addLog("NTRIP 连接错误: $e");
          disconnect();
        },
        onDone: () {
          addLog("NTRIP 连接已关闭");
          disconnect();
        },
      );
    } catch (e) {
      addLog("连接异常: $e");
      disconnect();
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await _socketSubscription?.cancel();
    _socketSubscription = null;

    var socket = _socket;
    _socket = null;
    socket?.destroy();

    if (_isConnected) {
      _isConnected = false;
      notifyListeners();
      addLog("已断开连接");
    }
  }

  Future<void> sendGNGGA(String gngga) async {
    if (_socket != null && _isConnected) {
      try {
        _socket!.write("$gngga\r\n");
        addLog("GNGGA 发送成功: $gngga");
      } catch (e) {
        addLog("GNGGA 发送失败: $e");
      }
    }
  }

  String _buildNtripRequest(String mountPoint, String user, String password) {
    StringBuffer sb = StringBuffer();
    sb.write("GET /$mountPoint HTTP/1.0\r\n");
    sb.write("User-Agent: NTRIP FlutterClient/1.0\r\n");

    if (user.isNotEmpty) {
      String credentials = "$user:$password";
      String encoded = base64.encode(utf8.encode(credentials));
      sb.write("Authorization: Basic $encoded\r\n");
    }

    sb.write("\r\n");
    return sb.toString();
  }

  // Helper for getting mountpoints (stateless mostly, but uses logging)
  Future<List<String>> getMountPoints(String ip, int port) async {
    addLog("正在连接 $ip:$port 获取挂载点列表...");
    List<String> mps = [];
    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 5),
      );

      StringBuffer request = StringBuffer();
      request.write("GET / HTTP/1.0\r\n");
      request.write("User-Agent: NTRIP FlutterClient/1.0\r\n");
      request.write("Accept: */*\r\n");
      request.write("Connection: close\r\n");
      request.write("\r\n");

      addLog("发送请求:\n${request.toString().trim()}");
      socket.write(request.toString());

      List<int> buffer = [];
      await socket.forEach((data) {
        buffer.addAll(data);
      });

      String response;
      try {
        response = utf8.decode(buffer);
      } catch (e) {
        response = latin1.decode(buffer);
      }

      addLog("收到响应 (原始数据):\n$response");

      LineSplitter.split(response).forEach((line) {
        if (line.startsWith("STR;")) {
          var parts = line.split(';');
          if (parts.length > 1) {
            mps.add(parts[1]);
          }
        }
      });

      addLog("解析成功: 找到 ${mps.length} 个挂载点");
    } catch (e) {
      addLog("获取挂载点失败: $e");
    } finally {
      socket?.destroy();
    }
    return mps;
  }
}
