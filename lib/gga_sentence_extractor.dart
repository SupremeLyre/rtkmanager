class GgaSentenceExtractor {
  static const List<int> _gnggaPrefix = [
    0x24, // $
    0x47, // G
    0x4e, // N
    0x47, // G
    0x47, // G
    0x41, // A
    0x2c, // ,
  ];
  static const List<int> _gpggaPrefix = [
    0x24, // $
    0x47, // G
    0x50, // P
    0x47, // G
    0x47, // G
    0x41, // A
    0x2c, // ,
  ];
  static const int _maxSentenceLength = 1024;

  final List<int> _buffer = [];

  List<String> add(List<int> data) {
    _buffer.addAll(data);
    final sentences = <String>[];

    while (true) {
      final start = _findStart();
      if (start < 0) {
        _keepPossiblePrefix();
        break;
      }

      if (start > 0) {
        _buffer.removeRange(0, start);
      }

      final nextStart = _findStart(1);
      final checksumMarker = _buffer.indexOf(0x2a, _gnggaPrefix.length);
      if (nextStart >= 0 &&
          (checksumMarker < 0 || nextStart < checksumMarker)) {
        _buffer.removeRange(0, nextStart);
        continue;
      }

      if (checksumMarker < 0) {
        if (_buffer.length > _maxSentenceLength) {
          _buffer.removeAt(0);
          continue;
        }
        break;
      }

      final sentenceEnd = checksumMarker + 3;
      if (sentenceEnd > _maxSentenceLength) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < sentenceEnd) {
        break;
      }

      if (!_isHexDigit(_buffer[checksumMarker + 1]) ||
          !_isHexDigit(_buffer[checksumMarker + 2]) ||
          !_isPrintableAscii(0, sentenceEnd)) {
        _buffer.removeAt(0);
        continue;
      }

      sentences.add(String.fromCharCodes(_buffer.getRange(0, sentenceEnd)));
      _buffer.removeRange(0, sentenceEnd);
    }

    return sentences;
  }

  int _findStart([int from = 0]) {
    for (var i = from; i <= _buffer.length - _gnggaPrefix.length; i++) {
      if (_matchesAt(i, _gnggaPrefix) || _matchesAt(i, _gpggaPrefix)) {
        return i;
      }
    }
    return -1;
  }

  bool _matchesAt(int index, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (_buffer[index + i] != prefix[i]) {
        return false;
      }
    }
    return true;
  }

  bool _isPrintableAscii(int start, int end) {
    for (var i = start; i < end; i++) {
      if (_buffer[i] < 0x20 || _buffer[i] > 0x7e) {
        return false;
      }
    }
    return true;
  }

  void _keepPossiblePrefix() {
    final bytesToKeep = _gnggaPrefix.length - 1;
    if (_buffer.length > bytesToKeep) {
      _buffer.removeRange(0, _buffer.length - bytesToKeep);
    }
  }

  static bool _isHexDigit(int byte) {
    return (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x46) ||
        (byte >= 0x61 && byte <= 0x66);
  }
}
