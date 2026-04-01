import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'serial_service.dart';
import 'satellite_info.dart';

class SatellitePage extends StatefulWidget {
  final VoidCallback onOpenDrawer;

  const SatellitePage({super.key, required this.onOpenDrawer});

  @override
  State<SatellitePage> createState() => _SatellitePageState();
}

class _SatellitePageState extends State<SatellitePage> {
  final SatelliteService _satelliteService = SatelliteService();
  StreamSubscription<String>? _subscription;
  Timer? _cleanupTimer;

  @override
  void initState() {
    super.initState();
    // 页面初始化时清空之前的旧数据，避免显示过时信息
    _satelliteService.clear();

    _subscription = SerialService().lineStream.listen(_handleLine);

    // 定期清理过期的卫星数据 (每秒检查一次，清理超过3秒未更新的系统)
    _cleanupTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _satelliteService.pruneStaleData();
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _cleanupTimer?.cancel();
    super.dispose();
  }

  void _handleLine(String line) {
    // 处理 GSV 句子
    if (line.contains('GSV')) {
      _satelliteService.processGsvSentence(line);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '卫星信息',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: widget.onOpenDrawer,
        ),
      ),
      body: ListenableBuilder(
        listenable: _satelliteService,
        builder: (context, _) {
          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  // 统计信息
                  _buildStatisticsCard(),
                  const SizedBox(height: 12),
                  // 条形统计图 (信噪比)
                  _buildSnrBarChart(),
                  const SizedBox(height: 12),
                  // 极坐标图 (卫星高度角和方位角)
                  _buildPolarPlot(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 构建统计信息卡片
  Widget _buildStatisticsCard() {
    final satellites = _satelliteService.satellites;
    final gpsCount = satellites[SatelliteSystem.gps]!.length;
    final glonassCount = satellites[SatelliteSystem.glonass]!.length;
    final galileoCount = satellites[SatelliteSystem.galileo]!.length;
    final beidouCount = satellites[SatelliteSystem.beidou]!.length;
    final qzssCount = satellites[SatelliteSystem.qzss]?.length ?? 0;
    final navicCount = satellites[SatelliteSystem.navic]?.length ?? 0;
    final totalCount = _satelliteService.totalVisibleSatellites;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            const Text(
              '可见卫星统计',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceAround,
              spacing: 16.0,
              runSpacing: 8.0,
              children: [
                _buildStatItem('GPS', gpsCount, Colors.blue),
                _buildStatItem('GLONASS', glonassCount, Colors.red),
                _buildStatItem('Galileo', galileoCount, Colors.green),
                _buildStatItem('BeiDou', beidouCount, Colors.orange),
                _buildStatItem('QZSS', qzssCount, Colors.purple),
                _buildStatItem('NavIC', navicCount, Colors.teal),
                _buildStatItem('总计', totalCount, Colors.grey),
              ],
            ),
            if (_satelliteService.lastUpdate != null)
              Text(
                '最后更新: ${_satelliteService.lastUpdate!.toString().split('.')[0]}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  /// 构建极坐标图 (显示卫星的高度角和方位角)
  Widget _buildPolarPlot() {
    final satellites = _satelliteService.satellites;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '卫星分布 (高度角/方位角)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Center(
              child: SizedBox(
                width: 350,
                height: 350,
                child: CustomPaint(
                  painter: PolarPlotPainter(
                    allSatellites: _mergeSatellites(satellites),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildPolarLegend(),
          ],
        ),
      ),
    );
  }

  Widget _buildPolarLegend() {
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 16.0,
        runSpacing: 8.0,
        children: PolarPlotPainter.systemColors.entries.map((entry) {
          if (entry.key == SatelliteSystem.unknown) {
            return const SizedBox.shrink();
          }

          String label = '';
          switch (entry.key) {
            case SatelliteSystem.gps:
              label = 'GPS';
              break;
            case SatelliteSystem.glonass:
              label = 'GLONASS';
              break;
            case SatelliteSystem.galileo:
              label = 'Galileo';
              break;
            case SatelliteSystem.beidou:
              label = 'BeiDou';
              break;
            case SatelliteSystem.qzss:
              label = 'QZSS';
              break;
            case SatelliteSystem.navic:
              label = 'NavIC';
              break;
            default:
              label = '';
          }

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 12, height: 12, color: entry.value),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(fontSize: 12)),
            ],
          );
        }).toList(),
      ),
    );
  }

  /// 构建条形统计图 (信噪比)
  Widget _buildSnrBarChart() {
    final satellites = _satelliteService.satellites;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '信噪比分布 (按卫星系统)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _buildSystemSnrCharts(satellites),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemSnrCharts(
    Map<SatelliteSystem, List<SatelliteInfo>> satellites,
  ) {
    final systems = [
      (SatelliteSystem.gps, 'GPS', Colors.blue, 1, 32),
      (SatelliteSystem.glonass, 'GLONASS', Colors.red, 65, 96),
      (SatelliteSystem.galileo, 'Galileo', Colors.green, 1, 36),
      (SatelliteSystem.beidou, 'BeiDou', Colors.orange, 1, 63),
      (SatelliteSystem.qzss, 'QZSS', Colors.purple, 1, 10),
      (SatelliteSystem.navic, 'NavIC', Colors.teal, 1, 14),
    ];

    return Column(
      children: systems.map((systemInfo) {
        final system = systemInfo.$1;
        final name = systemInfo.$2;
        final color = systemInfo.$3;
        final defaultMin = systemInfo.$4;
        final defaultMax = systemInfo.$5;

        final satList = satellites[system] ?? [];

        // 即使没有卫星数据也显示图表框架，或者根据需求隐藏
        // 若要完全固定显示，就不应隐藏。
        // 但为了避免页面过长，如果该系统从未出现过数据，可能可以隐藏?
        // 用户要求"每次画图应该在前一帧的基础上进行更新"，暗示位置要固定。
        // 这里我们还是只显示有数据的系统，但是坐标轴固定。
        if (satList.isEmpty) {
          // 也可以选择显示空图表
          return SizedBox.shrink();
        }

        // 动态调整范围（针对GLONASS可能的不同ID情况）
        int minId = defaultMin;
        int maxId = defaultMax;

        if (satList.isNotEmpty) {
          int currentMin = satList.map((e) => e.satelliteId).reduce(min);
          int currentMax = satList.map((e) => e.satelliteId).reduce(max);

          // 如果发现ID完全偏离预设范围（例如GLONASS都在1-32），则调整
          if (currentMax < defaultMin || currentMin > defaultMax) {
            minId = 1;
            maxId = currentMax > 32 ? currentMax : 32;
          }
        }

        return Column(
          children: [
            Text(
              '$name (${satList.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 100,
              child: CustomPaint(
                painter: SnrBarChartPainter(
                  satellites: satList,
                  color: color,
                  minId: minId,
                  maxId: maxId,
                ),
                size: Size.infinite,
              ),
            ),
            const SizedBox(height: 12),
          ],
        );
      }).toList(),
    );
  }

  List<SatelliteInfo> _mergeSatellites(
    Map<SatelliteSystem, List<SatelliteInfo>> satellites,
  ) {
    final merged = <SatelliteInfo>[];
    satellites.forEach((_, sats) {
      merged.addAll(sats);
    });
    return merged;
  }
}

/// 极坐标图绘制器
class PolarPlotPainter extends CustomPainter {
  final List<SatelliteInfo> allSatellites;

  static const Map<SatelliteSystem, Color> systemColors = {
    SatelliteSystem.gps: Colors.blue,
    SatelliteSystem.glonass: Colors.red,
    SatelliteSystem.galileo: Colors.green,
    SatelliteSystem.beidou: Colors.orange,
    SatelliteSystem.qzss: Colors.purple,
    SatelliteSystem.navic: Colors.teal,
    SatelliteSystem.unknown: Colors.grey,
  };

  PolarPlotPainter({required this.allSatellites});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - 20;

    // 绘制背景和网格
    _drawBackground(canvas, center, radius, size);

    // 绘制卫星点
    _drawSatellites(canvas, center, radius);
  }

  void _drawBackground(Canvas canvas, Offset center, double radius, Size size) {
    // 绘制背景圆
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.grey[100]!
        ..style = PaintingStyle.fill,
    );

    // 绘制网格线 (高度角)
    final gridPaint = Paint()
      ..color = Colors.grey[300]!
      ..strokeWidth = 0.5;

    for (int el = 10; el <= 90; el += 20) {
      double gridRadius = radius * (1 - el / 90);
      canvas.drawCircle(center, gridRadius, gridPaint);
    }

    // 绘制方位角线
    final anglePaint = Paint()
      ..color = Colors.grey[400]!
      ..strokeWidth = 0.5;

    for (int az = 0; az < 360; az += 30) {
      final radians = az * pi / 180;
      final p1 = Offset(
        center.dx + radius * sin(radians),
        center.dy - radius * cos(radians),
      );
      final p2 = Offset(
        center.dx + radius * 1.1 * sin(radians),
        center.dy - radius * 1.1 * cos(radians),
      );
      canvas.drawLine(p1, p2, anglePaint);
    }

    // 绘制方位角标签
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final labels = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    for (int i = 0; i < 8; i++) {
      final angle = i * 45;
      final radians = angle * pi / 180;
      final x = center.dx + (radius + 25) * sin(radians);
      final y = center.dy - (radius + 25) * cos(radians);

      textPainter.text = TextSpan(
        text: labels[i],
        style: const TextStyle(color: Colors.black54, fontSize: 11),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(x - textPainter.width / 2, y - textPainter.height / 2),
      );
    }

    // 绘制高度角标签
    final elLabels = ['90°', '70°', '50°', '30°', '10°', '0°'];
    for (int i = 0; i < elLabels.length; i++) {
      final el = 90 - i * 18;
      final r = radius * (1 - el / 90);

      textPainter.text = TextSpan(
        text: elLabels[i],
        style: const TextStyle(color: Colors.black38, fontSize: 9),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(center.dx - textPainter.width / 2, center.dy - r),
      );
    }
  }

  void _drawSatellites(Canvas canvas, Offset center, double radius) {
    final paint = Paint()..strokeWidth = 2;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (final sat in allSatellites) {
      // 计算极坐标位置
      final r = radius * (1 - sat.elevation / 90.0).clamp(0, 1);
      final radians = sat.azimuth * pi / 180;

      final x = center.dx + r * sin(radians);
      final y = center.dy - r * cos(radians);
      final offset = Offset(x, y);

      // 设置颜色
      paint.color = systemColors[sat.system] ?? Colors.grey;

      // 绘制卫星点
      canvas.drawCircle(offset, 4, paint);

      // 绘制卫星号标签
      textPainter.text = TextSpan(
        text: sat.satelliteId.toString().padLeft(2, '0'),
        style: const TextStyle(color: Colors.black87, fontSize: 9),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(offset.dx - textPainter.width / 2, offset.dy + 6),
      );
    }
  }

  @override
  bool shouldRepaint(PolarPlotPainter oldDelegate) {
    return oldDelegate.allSatellites != allSatellites;
  }
}

/// 信噪比条形图绘制器
class SnrBarChartPainter extends CustomPainter {
  final List<SatelliteInfo> satellites;
  final Color color;
  final int minId;
  final int maxId;

  SnrBarChartPainter({
    required this.satellites,
    required this.color,
    required this.minId,
    required this.maxId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 即使 satellites 为空，我们也画网格和坐标轴
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final gridPaint = Paint()
      ..color = Colors.grey[300]!
      ..strokeWidth = 0.5;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // 绘制Y轴网格线 (SNR 0-50)
    for (int snr = 0; snr <= 50; snr += 10) {
      final y = size.height - (snr / 50) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);

      // 标签
      textPainter.text = TextSpan(
        text: snr.toString(),
        style: const TextStyle(color: Colors.grey, fontSize: 8),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(-20, y - textPainter.height / 2));
    }

    final int count = maxId - minId + 1;
    if (count <= 0) return;

    final barSlotWidth = size.width / count;
    // 留一点间隙
    final barWidth = max(1.0, barSlotWidth * 0.8);
    final maxSnr = 50.0;

    // 创建快速查找表
    final satMap = {for (var s in satellites) s.satelliteId: s};

    // 遍历所有可能的 ID 位置
    for (int i = 0; i < count; i++) {
      final currentId = minId + i;
      final xCenter = barSlotWidth * (i + 0.5);

      // 如果该 ID 只有特定倍数才显示标签，防止太拥挤
      // 每5个显示一次，或者总数少时都显示
      bool showLabel =
          count <= 20 ||
          (currentId % 5 == 0) ||
          currentId == 1 ||
          currentId == maxId;

      if (showLabel) {
        textPainter.text = TextSpan(
          text: currentId.toString(),
          style: const TextStyle(color: Colors.black54, fontSize: 8),
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(xCenter - textPainter.width / 2, size.height + 2),
        );
      }

      // 如果有卫星数据，画柱子
      if (satMap.containsKey(currentId)) {
        final sat = satMap[currentId]!;
        final barHeight = (sat.snr / maxSnr).clamp(0, 1) * size.height;

        // 绘制条形
        canvas.drawRect(
          Rect.fromLTRB(
            xCenter - barWidth / 2,
            size.height - barHeight,
            xCenter + barWidth / 2,
            size.height,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(SnrBarChartPainter oldDelegate) {
    return oldDelegate.satellites != satellites ||
        oldDelegate.color != color ||
        oldDelegate.minId != minId ||
        oldDelegate.maxId != maxId;
  }
}
