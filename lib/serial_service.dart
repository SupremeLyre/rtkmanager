import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_libserialport/flutter_libserialport.dart';

class SerialService {
  static final SerialService _instance = SerialService._internal();
  static final Map<String, SerialService> _activeServices = {};

  static SerialService? getActiveService(String portName) {
    return _activeServices[portName];
  }

  factory SerialService() {
    return _instance;
  }

  /// Create a new independent instance of SerialService
  SerialService.create();

  SerialService._internal();

  SerialPort? _port;
  String? _currentPortName;
  SerialPortReader? _reader;
  bool _isOpen = false;

  // Stream for received data (raw bytes)
  final _dataStreamController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get dataStream => _dataStreamController.stream;

  // Stream for received lines (decoded string)
  final _lineStreamController = StreamController<String>.broadcast();
  Stream<String> get lineStream => _lineStreamController.stream;

  List<int> _buffer = [];

  bool get isOpen => _isOpen;
  SerialPort? get port => _port;

  void open(String portName, int baudRate, bool rts, bool dtr) {
    if (_isOpen) close();

    try {
      _port = SerialPort(portName);
      if (_port!.openReadWrite()) {
        _currentPortName = portName;
        _activeServices[portName] = this;

        SerialPortConfig config = _port!.config;
        config.baudRate = baudRate;
        config.rts = rts ? 1 : 0;
        config.dtr = dtr ? 1 : 0;
        _port!.config = config;

        _reader = SerialPortReader(_port!);
        _reader!.stream.listen(
          (data) {
            _dataStreamController.add(data);
            _processLines(data);
          },
          onError: (error) {
            if (_isOpen) {
              close();
              if (!_dataStreamController.isClosed) {
                _dataStreamController.addError(error);
              }
              if (!_lineStreamController.isClosed) {
                _lineStreamController.addError(error);
              }
            }
          },
        );

        _isOpen = true;
      } else {
        throw SerialPort.lastError ?? Exception("Failed to open port");
      }
    } catch (e) {
      _isOpen = false;
      rethrow;
    }
  }

  void close() {
    if (_currentPortName != null) {
      _activeServices.remove(_currentPortName);
      _currentPortName = null;
    }
    if (_port != null && _port!.isOpen) {
      _reader?.close();
      _port!.close();
    }
    _isOpen = false;
    _port = null;
    _reader = null;
    _buffer.clear();
  }

  int write(Uint8List data) {
    if (_isOpen && _port != null) {
      try {
        return _port!.write(data);
      } catch (e) {
        close();
        rethrow;
      }
    }
    return 0;
  }

  void _processLines(Uint8List data) {
    _buffer.addAll(data);

    int index;
    while ((index = _buffer.indexOf(10)) != -1) {
      // 10 is \n
      List<int> lineBytes = _buffer.sublist(0, index + 1);
      _buffer = _buffer.sublist(index + 1);

      try {
        // Decode as UTF-8, allowing malformed sequences to avoid crashes
        String line = utf8.decode(lineBytes, allowMalformed: true).trim();
        _lineStreamController.add(line);
      } catch (e) {
        // Handle decoding errors if necessary
      }
    }
  }

  void dispose() {
    _dataStreamController.close();
    _lineStreamController.close();
    close();
  }
}
