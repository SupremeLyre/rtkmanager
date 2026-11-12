import 'dart:convert';
import 'dart:io';

enum TruthField {
  gpsWeek,
  gpsSeconds,
  utcTime,
  latitude,
  longitude,
  height,
  velocityEast,
  velocityNorth,
  velocityUp,
  roll,
  pitch,
  heading,
}

DateTime gpsTimeToUtc(
  int week,
  double seconds, {
  int gpsUtcOffsetSeconds = 18,
}) {
  if (week < 0 ||
      week > 10000 ||
      !seconds.isFinite ||
      seconds < 0 ||
      seconds >= 604800) {
    throw const FormatException('GPS 周或周内秒超出有效范围。');
  }
  if (gpsUtcOffsetSeconds < 0 || gpsUtcOffsetSeconds > 60) {
    throw const FormatException('GPS−UTC 秒差应在 0 到 60 秒之间。');
  }
  return DateTime.utc(1980, 1, 6).add(
    Duration(
      microseconds: ((week * 604800 + seconds - gpsUtcOffsetSeconds) * 1000000)
          .round(),
    ),
  );
}

class TruthColumnMapping {
  TruthColumnMapping({required Map<TruthField, int> columns, this.delimiter})
    : columns = Map.unmodifiable(columns);

  final Map<TruthField, int> columns;
  final String? delimiter;

  int? operator [](TruthField field) => columns[field];

  static TruthColumnMapping autoDetect(
    List<String> header, {
    String? delimiter,
  }) {
    final columns = <TruthField, int>{};
    for (var i = 0; i < header.length; i++) {
      final name = header[i].toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      final field = _aliases[name];
      if (field != null) columns.putIfAbsent(field, () => i);
    }
    return TruthColumnMapping(columns: columns, delimiter: delimiter);
  }

  static const _aliases = {
    'week': TruthField.gpsWeek,
    'gpsweek': TruthField.gpsWeek,
    'gpsw': TruthField.gpsWeek,
    'gpstime': TruthField.gpsSeconds,
    'gpsseconds': TruthField.gpsSeconds,
    'gpst': TruthField.gpsSeconds,
    'tow': TruthField.gpsSeconds,
    'secondsofweek': TruthField.gpsSeconds,
    'sow': TruthField.gpsSeconds,
    'utc': TruthField.utcTime,
    'utctime': TruthField.utcTime,
    'utcdatetime': TruthField.utcTime,
    'timestamp': TruthField.utcTime,
    'datetime': TruthField.utcTime,
    'latitude': TruthField.latitude,
    'lat': TruthField.latitude,
    'latitudedeg': TruthField.latitude,
    'longitude': TruthField.longitude,
    'lon': TruthField.longitude,
    'long': TruthField.longitude,
    'lng': TruthField.longitude,
    'longitudedeg': TruthField.longitude,
    'hell': TruthField.height,
    'height': TruthField.height,
    'ellipsoidheight': TruthField.height,
    'altitude': TruthField.height,
    'alt': TruthField.height,
    'veast': TruthField.velocityEast,
    've': TruthField.velocityEast,
    'velocityeast': TruthField.velocityEast,
    'eastvelocity': TruthField.velocityEast,
    'vnorth': TruthField.velocityNorth,
    'vn': TruthField.velocityNorth,
    'velocitynorth': TruthField.velocityNorth,
    'northvelocity': TruthField.velocityNorth,
    'vup': TruthField.velocityUp,
    'vu': TruthField.velocityUp,
    'velocityup': TruthField.velocityUp,
    'upvelocity': TruthField.velocityUp,
    'roll': TruthField.roll,
    'rolldeg': TruthField.roll,
    'pitch': TruthField.pitch,
    'pitchdeg': TruthField.pitch,
    'heading': TruthField.heading,
    'headingdeg': TruthField.heading,
    'yaw': TruthField.heading,
    'azimuth': TruthField.heading,
  };
}

class TruthSample {
  const TruthSample({
    required this.utcTime,
    required this.latitude,
    required this.longitude,
    this.height,
    this.velocityEast,
    this.velocityNorth,
    this.velocityUp,
    this.roll,
    this.pitch,
    this.heading,
  });

  final DateTime utcTime;
  final double latitude;
  final double longitude;
  final double? height;
  final double? velocityEast;
  final double? velocityNorth;
  final double? velocityUp;
  final double? roll;
  final double? pitch;
  final double? heading;
}

class TruthDataset {
  TruthDataset({
    required this.sourcePath,
    required List<TruthSample> samples,
    TruthColumnMapping? mapping,
    List<String> headers = const [],
    this.skippedRows = 0,
  }) : samples = List.unmodifiable(samples),
       mapping = mapping ?? TruthColumnMapping(columns: {}),
       headers = List.unmodifiable(headers);

  final String sourcePath;
  final List<TruthSample> samples;
  final TruthColumnMapping mapping;
  final List<String> headers;
  final int skippedRows;
}

class TruthFilePreview {
  TruthFilePreview({
    required List<String> headers,
    required List<List<String>> exampleRows,
    required this.mapping,
    required this.headerLineIndex,
  }) : headers = List.unmodifiable(headers),
       exampleRows = List.unmodifiable(
         exampleRows.map((row) => List<String>.unmodifiable(row)),
       );

  final List<String> headers;
  final List<List<String>> exampleRows;
  final TruthColumnMapping mapping;
  final int? headerLineIndex;
  TruthColumnMapping get detectedMapping => mapping;
}

Future<TruthFilePreview> previewTruthFile(String path) async {
  var headers = <String>[];
  var examples = <List<String>>[];
  var mapping = TruthColumnMapping(columns: {});
  int? headerLineIndex;
  var lineIndex = 0;
  String? delimiter;
  await for (final line in _fileLines(path)) {
    final content = _content(line);
    if (content.isEmpty) {
      lineIndex++;
      continue;
    }
    final currentDelimiter = delimiter ?? _detectDelimiter(content);
    final tokens = _split(content, currentDelimiter);
    final detected = TruthColumnMapping.autoDetect(
      tokens,
      delimiter: currentDelimiter,
    );
    if (_hasCoordinates(detected)) {
      headers = tokens;
      mapping = detected;
      delimiter = currentDelimiter;
      headerLineIndex = lineIndex;
      examples = [];
    } else if (!_isComment(line) && !_isUnits(tokens)) {
      if (headers.isEmpty && _looksLikeData(tokens)) {
        headers = List.generate(tokens.length, (i) => '列 ${i + 1}');
        delimiter = currentDelimiter;
        mapping = TruthColumnMapping(columns: {}, delimiter: delimiter);
      }
      if (headers.isNotEmpty && _looksLikeData(tokens)) examples.add(tokens);
    }
    if (examples.length == 3 || lineIndex >= 99) break;
    lineIndex++;
  }
  if (headers.isEmpty) throw const FormatException('未找到真值表头或数据列。');
  return TruthFilePreview(
    headers: headers,
    exampleRows: examples,
    mapping: mapping,
    headerLineIndex: headerLineIndex,
  );
}

Future<TruthDataset> readTruthFile(
  String path, {
  TruthColumnMapping? mapping,
  int gpsUtcOffsetSeconds = 18,
}) async {
  final parser = _TruthParser(path, mapping, gpsUtcOffsetSeconds);
  await for (final line in _fileLines(path)) {
    parser.addLine(line);
  }
  return parser.finish();
}

TruthDataset parseTruthText(
  String text, {
  String sourcePath = '',
  TruthColumnMapping? mapping,
  int gpsUtcOffsetSeconds = 18,
}) {
  final parser = _TruthParser(sourcePath, mapping, gpsUtcOffsetSeconds);
  for (final line in const LineSplitter().convert(text)) {
    parser.addLine(line);
  }
  return parser.finish();
}

Stream<String> _fileLines(String path) => File(path)
    .openRead()
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter());

class _TruthParser {
  _TruthParser(this.sourcePath, this.mapping, this.gpsUtcOffsetSeconds) {
    if (gpsUtcOffsetSeconds < 0 || gpsUtcOffsetSeconds > 60) {
      throw const FormatException('GPS−UTC 秒差应在 0 到 60 秒之间。');
    }
    if (mapping != null) _validateMapping(mapping!);
  }

  final String sourcePath;
  TruthColumnMapping? mapping;
  final int gpsUtcOffsetSeconds;
  List<String> headers = [];
  String? detectedDelimiter;
  final samples = <int, TruthSample>{};
  var skippedRows = 0;

  void addLine(String line) {
    final content = _content(line);
    if (content.isEmpty) return;
    final delimiter =
        mapping?.delimiter ?? detectedDelimiter ?? _detectDelimiter(content);
    final tokens = _split(content, delimiter);
    final detected = TruthColumnMapping.autoDetect(
      tokens,
      delimiter: delimiter,
    );
    if (_hasCoordinates(detected)) {
      headers = tokens;
      detectedDelimiter = delimiter;
      mapping ??= detected;
      _validateMapping(mapping!);
      return;
    }
    if (_isComment(line) || _isUnits(tokens)) return;
    if (mapping == null) {
      if (_looksLikeData(tokens)) {
        throw const FormatException('无法自动识别真值列，请手动指定经纬度和时间列。');
      }
      return;
    }
    detectedDelimiter ??= delimiter;
    final latitude = _number(tokens, TruthField.latitude);
    final longitude = _number(tokens, TruthField.longitude);
    final utcTime = _time(tokens);
    if (latitude == null ||
        longitude == null ||
        latitude.abs() > 90 ||
        longitude.abs() > 180 ||
        utcTime == null) {
      skippedRows++;
      return;
    }
    final sample = TruthSample(
      utcTime: utcTime,
      latitude: latitude,
      longitude: longitude,
      height: _number(tokens, TruthField.height),
      velocityEast: _number(tokens, TruthField.velocityEast),
      velocityNorth: _number(tokens, TruthField.velocityNorth),
      velocityUp: _number(tokens, TruthField.velocityUp),
      roll: _number(tokens, TruthField.roll),
      pitch: _number(tokens, TruthField.pitch),
      heading: _number(tokens, TruthField.heading),
    );
    // A corrected later row replaces an earlier sample at the same epoch.
    samples[utcTime.microsecondsSinceEpoch] = sample;
  }

  double? _number(List<String> row, TruthField field) {
    final index = mapping![field];
    if (index == null || index >= row.length) return null;
    return _finiteNumber(row[index]);
  }

  DateTime? _time(List<String> row) {
    final utcIndex = mapping![TruthField.utcTime];
    if (utcIndex != null && utcIndex < row.length) {
      final token = row[utcIndex].trim();
      final seconds = _finiteNumber(token);
      if (seconds != null &&
          seconds.abs() >= 100000000 &&
          seconds.abs() < 8640000000000) {
        return DateTime.fromMicrosecondsSinceEpoch(
          (seconds * 1000000).round(),
          isUtc: true,
        );
      }
      if (token.contains(RegExp(r'[-T:]'))) {
        final parsed = _strictUtcTime(token);
        if (parsed != null) return parsed;
      }
    }
    final week = _number(row, TruthField.gpsWeek);
    final seconds = _number(row, TruthField.gpsSeconds);
    if (week == null ||
        seconds == null ||
        week != week.roundToDouble() ||
        week < 0 ||
        week > 10000 ||
        seconds < 0 ||
        seconds >= 604800) {
      return null;
    }
    return gpsTimeToUtc(
      week.toInt(),
      seconds,
      gpsUtcOffsetSeconds: gpsUtcOffsetSeconds,
    );
  }

  TruthDataset finish() {
    if (mapping == null) throw const FormatException('未找到可识别的真值列。');
    if (samples.isEmpty) throw const FormatException('真值文件中没有有效的时间和经纬度数据。');
    final sorted = samples.values.toList()
      ..sort((a, b) => a.utcTime.compareTo(b.utcTime));
    return TruthDataset(
      sourcePath: sourcePath,
      samples: sorted,
      mapping: mapping!,
      headers: headers,
      skippedRows: skippedRows,
    );
  }
}

DateTime? _strictUtcTime(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?(?:[Zz]|[+-](\d{2}):?(\d{2}))?)?$',
  ).firstMatch(value);
  if (match == null) return null;
  int field(int index) => int.parse(match[index] ?? '0');
  final year = field(1), month = field(2), day = field(3);
  final date = DateTime.utc(year, month, day);
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      field(4) > 23 ||
      field(5) > 59 ||
      field(6) > 59 ||
      field(7) > 23 ||
      field(8) > 59) {
    return null;
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return parsed.isUtc
      ? parsed
      : DateTime.utc(
          parsed.year,
          parsed.month,
          parsed.day,
          parsed.hour,
          parsed.minute,
          parsed.second,
          parsed.millisecond,
          parsed.microsecond,
        );
}

void _validateMapping(TruthColumnMapping mapping) {
  if (mapping.columns.values.any((index) => index < 0)) {
    throw const FormatException('列索引不能为负数。');
  }
  if (mapping[TruthField.latitude] == null ||
      mapping[TruthField.longitude] == null) {
    throw const FormatException('请选择经度和纬度列。');
  }
  if (mapping[TruthField.utcTime] == null &&
      (mapping[TruthField.gpsWeek] == null ||
          mapping[TruthField.gpsSeconds] == null)) {
    throw const FormatException('请选择 UTC 时间列，或 GPS 周和周内秒列。');
  }
}

bool _hasCoordinates(TruthColumnMapping mapping) =>
    mapping[TruthField.latitude] != null &&
    mapping[TruthField.longitude] != null;

String _content(String line) =>
    line.trim().replaceFirst(RegExp(r'^[\uFEFF#%]+\s*'), '');

bool _isComment(String line) => line.trimLeft().startsWith(RegExp(r'[#%]'));

String _detectDelimiter(String line) => line.contains(',')
    ? ','
    : line.contains('\t')
    ? '\t'
    : 'whitespace';

List<String> _split(String line, String delimiter) => delimiter == 'whitespace'
    ? line.trim().split(RegExp(r'\s+'))
    : line
          .split(delimiter)
          .map((part) => part.trim().replaceAll(RegExp(r'^"|"$'), ''))
          .toList();

double? _finiteNumber(String text) {
  final value = double.tryParse(text.trim().replaceAll(RegExp(r'[dD]'), 'e'));
  return value != null && value.isFinite ? value : null;
}

bool _looksLikeData(List<String> tokens) =>
    tokens.any((token) => _finiteNumber(token) != null) ||
    tokens.any(
      (token) => token.contains('T') && DateTime.tryParse(token) != null,
    );

bool _isUnits(List<String> tokens) =>
    tokens.any((token) => token.contains('(deg)') || token.contains('(sec)'));
