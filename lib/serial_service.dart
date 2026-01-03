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

  // Stream for raw decoded text (no line splitting)
  final _textStreamController = StreamController<String>.broadcast();
  Stream<String> get textStream => _textStreamController.stream;

  List<int> _buffer = [];
  ByteConversionSink? _textConversionSink;

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
        config.bits = 8;
        config.stopBits = 1;
        config.parity = 0; // None
        config.rts = rts ? 1 : 0;
        config.dtr = dtr ? 1 : 0;
        config.xonXoff = 0; // Disable software flow control
        _port!.config = config;

        // Setup raw text decoder
        _textConversionSink = utf8.decoder.startChunkedConversion(
          _SafeSink(_textStreamController),
        );

        _reader = SerialPortReader(_port!);
        _reader!.stream.listen(
          (data) {
            _dataStreamController.add(data);
            _processLines(data);
            _textConversionSink?.add(data);
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
              if (!_textStreamController.isClosed) {
                _textStreamController.addError(error);
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
    _textConversionSink?.close();
    _textConversionSink = null;
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

    int lastIndex = 0;
    bool foundLine = false;

    // Scan for newlines efficiently
    for (int i = 0; i < _buffer.length; i++) {
      if (_buffer[i] == 10) { // 10 is \n
        List<int> lineBytes = _buffer.sublist(lastIndex, i + 1);
        try {
          String line = utf8.decode(lineBytes, allowMalformed: true).trim();
          if (line.isNotEmpty) {
            _lineStreamController.add(line);
          }
        } catch (e) {
          // Ignore decode errors
        }
        lastIndex = i + 1;
        foundLine = true;
      }
    }

    // Remove processed data
    if (foundLine) {
      if (lastIndex >= _buffer.length) {
        _buffer.clear();
      } else {
        _buffer = _buffer.sublist(lastIndex);
      }
    }

    // Safety: prevent buffer from growing indefinitely if no newline found
    // This prevents memory issues on low-end devices like Raspberry Pi
    if (_buffer.length > 4096) {
      // Keep only the last 1024 bytes to recover from overflow
      _buffer = _buffer.sublist(_buffer.length - 1024);
    }
  }

  void dispose() {
    _dataStreamController.close();
    _lineStreamController.close();
    _textStreamController.close();
    close();
  }
}

class _SafeSink<T> implements Sink<T> {
  final StreamController<T> _controller;

  _SafeSink(this._controller);

  @override
  void add(T data) {
    if (!_controller.isClosed) {
      _controller.add(data);
    }
  }

  @override
  void close() {
    // Do not close the controller
  }
}
