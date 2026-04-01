import 'dart:async';
import 'package:flutter/foundation.dart';

/// 卫星系统枚举
enum SatelliteSystem {
  gps, // GPS (G)
  glonass, // GLONASS (R)
  galileo, // Galileo (E)
  beidou, // BeiDou (C)
  qzss, // QZSS (J)
  navic, // NavIC (I)
  unknown,
}

/// 单个卫星信息
class SatelliteInfo {
  final int satelliteId; // 卫星号
  final int elevation; // 高度角 (0-90)
  final int azimuth; // 方位角 (0-360)
  final int snr; // 信噪比 (0-99 dB-Hz)
  final SatelliteSystem system; // 卫星系统
  final bool isUsedInFix; // 是否用于定位

  SatelliteInfo({
    required this.satelliteId,
    required this.elevation,
    required this.azimuth,
    required this.snr,
    required this.system,
    this.isUsedInFix = false,
  });

  factory SatelliteInfo.fromGsv(List<String> fields, SatelliteSystem system) {
    // GSV 格式: $GLGSV,3,1,11,01,45,049,47,02,17,308,41,03,04,224,00,04,51,099,47*22
    // 每颗卫星数据: 卫星号,高度角,方位角,信噪比
    return SatelliteInfo(
      satelliteId: int.tryParse(fields[0]) ?? 0,
      elevation: int.tryParse(fields[1]) ?? 0,
      azimuth: int.tryParse(fields[2]) ?? 0,
      snr: int.tryParse(fields[3]) ?? 0,
      system: system,
    );
  }

  @override
  String toString() =>
      'SatelliteInfo(id=$satelliteId, el=$elevation, az=$azimuth, snr=$snr, sys=$system)';
}

/// GSV 句子（一帧卫星信息）
class GsvSentence {
  final int totalSentences; // 总的 GSV 句子数
  final int sentenceIndex; // 当前句子号
  final int totalSatellites; // 总卫星数
  final List<SatelliteInfo> satellites; // 本句子包含的卫星信息
  final SatelliteSystem system;
  final String signalId; // 信号 ID (NMEA 4.10+)

  GsvSentence({
    required this.totalSentences,
    required this.sentenceIndex,
    required this.totalSatellites,
    required this.satellites,
    required this.system,
    required this.signalId,
  });

  factory GsvSentence.parse(String sentence) {
    if (!sentence.startsWith('\$')) {
      throw FormatException('Invalid NMEA sentence: $sentence');
    }

    // 移除 $ 和校验和部分
    String data = sentence.substring(1);
    if (data.contains('*')) {
      data = data.substring(0, data.indexOf('*'));
    }

    List<String> parts = data.split(',');
    if (parts.length < 4) {
      throw FormatException('Invalid GSV format: $sentence');
    }

    String header = parts[0];
    SatelliteSystem system = _parseSystem(header);

    int totalSentences = int.tryParse(parts[1]) ?? 1;
    int sentenceIndex = int.tryParse(parts[2]) ?? 1;
    int totalSatellites = int.tryParse(parts[3]) ?? 0;

    List<SatelliteInfo> satellites = [];

    // 计算是否有 Signal ID
    // Header(1) + Total(1) + Index(1) + Count(1) = 4 fields.
    // Each sat has 4 fields.
    // Checksum/SignalID handling:
    // If (parts.length - 4) % 4 == 1, then the last field is Signal ID.
    String signalId = '0'; // Default to '0' (or '1' usually for single signal)

    int dataFieldCount = parts.length - 4;
    if (dataFieldCount > 0 && dataFieldCount % 4 == 1) {
      signalId = parts.last;
      // Adjust count to exclude signal ID
      dataFieldCount--;
    }

    // 解析卫星数据
    int satCount = dataFieldCount ~/ 4;
    for (int i = 0; i < satCount; i++) {
      int baseIndex = 4 + i * 4;
      if (baseIndex + 3 < parts.length) {
        try {
          List<String> satFields = [
            parts[baseIndex],
            parts[baseIndex + 1],
            parts[baseIndex + 2],
            parts[baseIndex + 3],
          ];
          satellites.add(SatelliteInfo.fromGsv(satFields, system));
        } catch (e) {
          // Skip
        }
      }
    }

    return GsvSentence(
      totalSentences: totalSentences,
      sentenceIndex: sentenceIndex,
      totalSatellites: totalSatellites,
      satellites: satellites,
      system: system,
      signalId: signalId,
    );
  }

  static SatelliteSystem _parseSystem(String header) {
    if (header.contains('GL')) return SatelliteSystem.glonass;
    if (header.contains('GP')) return SatelliteSystem.gps;
    if (header.contains('GA')) return SatelliteSystem.galileo;
    if (header.contains('GB') || header.contains('BD'))
      return SatelliteSystem.beidou; // GB/BD commonly used for BeiDou
    if (header.contains('GI')) return SatelliteSystem.navic; // NavIC
    if (header.contains('GQ')) return SatelliteSystem.qzss; // QZSS
    if (header.contains('GN')) return SatelliteSystem.unknown;
    return SatelliteSystem.unknown;
  }

  @override
  String toString() =>
      'GsvSentence($sentenceIndex/$totalSentences, $totalSatellites sats, sys=$system, sig=$signalId)';
}

/// 卫星信息管理服务
class SatelliteService extends ChangeNotifier {
  static final SatelliteService _instance = SatelliteService._internal();

  factory SatelliteService() {
    return _instance;
  }

  SatelliteService._internal();

  // 最终的卫星显示列表 (合并了各个信号源的)
  final Map<SatelliteSystem, List<SatelliteInfo>> _satellites = {
    SatelliteSystem.gps: [],
    SatelliteSystem.glonass: [],
    SatelliteSystem.galileo: [],
    SatelliteSystem.beidou: [],
    SatelliteSystem.qzss: [],
    SatelliteSystem.navic: [],
  };

  // 缓存区: System -> { SignalId -> { Index -> Sentence } }
  final Map<SatelliteSystem, Map<String, Map<int, GsvSentence>>>
  _signalBuffers = {};

  // 已解析的各信号源数据: System -> { SignalId -> List<SatelliteInfo> }
  final Map<SatelliteSystem, Map<String, List<SatelliteInfo>>> _signalData = {};

  final Map<SatelliteSystem, DateTime> _systemLastUpdates = {};
  Timer? _debounceTimer;
  DateTime? _lastUpdate;
  int _totalVisibleSatellites = 0;

  // Getters
  Map<SatelliteSystem, List<SatelliteInfo>> get satellites =>
      Map.unmodifiable(_satellites);
  List<SatelliteInfo> getSatellitesForSystem(SatelliteSystem system) =>
      List.unmodifiable(_satellites[system] ?? []);
  DateTime? get lastUpdate => _lastUpdate;
  int get totalVisibleSatellites => _totalVisibleSatellites;

  /// 处理 GSV 句子
  void processGsvSentence(String sentence) {
    try {
      final gsv = GsvSentence.parse(sentence);
      if (gsv.system == SatelliteSystem.unknown) return;

      // 1. 初始化缓冲区结构
      if (!_signalBuffers.containsKey(gsv.system)) {
        _signalBuffers[gsv.system] = {};
        _signalData[gsv.system] = {};
      }
      final sysBuffer = _signalBuffers[gsv.system]!;

      if (!sysBuffer.containsKey(gsv.signalId)) {
        sysBuffer[gsv.signalId] = {};
      }
      final msgBuffer = sysBuffer[gsv.signalId]!;

      // 2. 缓冲逻辑
      // 如果收到第一帧，或者 totalSentences 发生变化，则重置该 SignalId 的缓冲区
      if (gsv.sentenceIndex == 1) {
        msgBuffer.clear();
      } else if (msgBuffer.isNotEmpty &&
          msgBuffer.values.first.totalSentences != gsv.totalSentences) {
        msgBuffer.clear();
      }

      msgBuffer[gsv.sentenceIndex] = gsv;

      // 3. 检查是否接收完整
      if (msgBuffer.length == gsv.totalSentences) {
        // 提取该信号源的所有卫星
        final fullSet = <SatelliteInfo>[];
        // 排序
        final sentences = msgBuffer.values.toList()
          ..sort((a, b) => a.sentenceIndex.compareTo(b.sentenceIndex));

        for (var s in sentences) {
          fullSet.addAll(s.satellites);
        }

        // 更新该信号源的数据
        _signalData[gsv.system]![gsv.signalId] = fullSet;
        msgBuffer.clear(); // 清空缓冲区准备下一轮

        // 标记更新时间
        _systemLastUpdates[gsv.system] = DateTime.now();

        // 触发合并和 UI 更新
        _scheduleUpdate(gsv.system);
      }
    } catch (e) {
      // ignore
    }
  }

  void _scheduleUpdate(SatelliteSystem system) {
    // 这里我们立即更新数据以响应"下一帧来了之后直接更新画布"的需求，
    // 但仍然使用微小的防抖来合并同一瞬间的多个信号更新
    if (_debounceTimer?.isActive ?? false) return;
    _debounceTimer = Timer(const Duration(milliseconds: 50), () {
      _mergeAndNotify();
      _debounceTimer = null;
    });
  }

  void _mergeAndNotify() {
    int total = 0;

    // 遍历所有系统的所有信号数据进行合并
    for (var system in SatelliteSystem.values) {
      if (system == SatelliteSystem.unknown || !_signalData.containsKey(system))
        continue;

      final systemSignals = _signalData[system]!;
      if (systemSignals.isEmpty) {
        _satellites[system]?.clear();
        continue;
      }

      // 合并策略: 以 PRN 为 key，保留 SNR 最大的那个
      final mergedMap = <int, SatelliteInfo>{};

      for (var satList in systemSignals.values) {
        for (var sat in satList) {
          if (!mergedMap.containsKey(sat.satelliteId)) {
            mergedMap[sat.satelliteId] = sat;
          } else {
            // 如果已存在，比较 SNR，保留较大的
            if (sat.snr > mergedMap[sat.satelliteId]!.snr) {
              mergedMap[sat.satelliteId] = sat;
            }
          }
        }
      }

      final mergedList = mergedMap.values.toList()
        ..sort((a, b) => a.satelliteId.compareTo(b.satelliteId)); // 排序

      _satellites[system] = mergedList;
      total += mergedList.length;
    }

    _totalVisibleSatellites = total;
    _lastUpdate = DateTime.now();
    notifyListeners();
  }

  /// 移除过期的卫星数据
  void pruneStaleData({Duration timeout = const Duration(seconds: 3)}) {
    final now = DateTime.now();
    bool changed = false;

    for (var system in SatelliteSystem.values) {
      if (system == SatelliteSystem.unknown) continue;

      final lastUpdate = _systemLastUpdates[system];
      if (lastUpdate != null && now.difference(lastUpdate) > timeout) {
        // 清除该系统所有数据
        if (_signalData.containsKey(system) &&
            _signalData[system]!.isNotEmpty) {
          _signalData[system]!.clear();
          changed = true;
        }
        _signalBuffers[system]?.clear();
      }
    }

    if (changed) {
      _mergeAndNotify();
    }
  }

  /// 清空所有卫星信息
  void clear() {
    _satellites.forEach((key, value) => value.clear());
    _signalBuffers.clear();
    _signalData.clear();
    _systemLastUpdates.clear();
    _totalVisibleSatellites = 0;
    _lastUpdate = null;
    _debounceTimer?.cancel();
    notifyListeners();
  }
}
