import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'serial_service.dart';
import 'imu_data_parser.dart';
import 'gga_sentence_extractor.dart';
import 'gnss_ble_service.dart';
import 'app_ui.dart';
import 'position_data.dart';
import 'map_layer_controller.dart';
import 'map_layer_panel.dart';
import 'mqtt_position_service.dart';
import 'mqtt_connection_panel.dart';
import 'mqtt_archive_panel.dart';

export 'position_data.dart';

class MobilePositioningPage extends StatefulWidget {
  final VoidCallback? onOpenDrawer;
  final bool ggaOnly;
  final GnssBleService? bluetooth;
  final MqttPositionService? mqtt;
  final ValueChanged<bool>? onImportingChanged;

  const MobilePositioningPage({
    super.key,
    this.onOpenDrawer,
    this.ggaOnly = false,
    this.bluetooth,
    this.mqtt,
    this.onImportingChanged,
  });

  @override
  State<MobilePositioningPage> createState() => _MobilePositioningPageState();
}

class _MobilePositioningPageState extends State<MobilePositioningPage> {
  static const int _maxMapZoom = 18;
  static const ColorFilter _mutedMapColorFilter = ColorFilter.matrix([
    0.15945,
    0.5364,
    0.05415,
    0,
    55,
    0.15945,
    0.5364,
    0.05415,
    0,
    55,
    0.15945,
    0.5364,
    0.05415,
    0,
    55,
    0,
    0,
    0,
    1,
    0,
  ]);

  final MapController _mapController = MapController();
  final List<PositionHistoryPoint> _points = [];
  StreamSubscription<String>? _subscription;
  StreamSubscription<Uint8List>? _ggaSubscription;
  StreamSubscription<ImuData>? _imuSubscription;
  StreamSubscription<String>? _bluetoothSubscription;
  GnssBleConnection _bluetoothConnection = GnssBleConnection.disconnected;
  bool _autoCenter = true;
  bool _showTimeline = true;
  final MapLayerController _localLayers = MapLayerController();
  final ValueNotifier<int> _localRevision = ValueNotifier(0);
  late final MqttPositionService _mqtt = widget.mqtt ?? MqttPositionService();
  bool _mqttMode = false;
  String? _mqttDeviceId;
  MqttPositionFix? _mqttShownFix;
  bool _isImportMode = false;
  bool _isImporting = false;
  double _importProgress = 0.0;
  int _trajectoryDetailLevel = 2;
  PositionInfo? _currentInfo;
  ImuData? _currentImuInfo;
  int? _selectedIndex;

  // Gaode Map Tile URL (Standard/Vector implementation)
  final String _amapUrl =
      'https://webrd{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}';

  @override
  void initState() {
    super.initState();
    _localLayers.ensureLayer('gga', label: 'GGA', color: Colors.green.shade800);
    if (!widget.ggaOnly) {
      _localLayers.ensureLayer(
        'pppsol',
        label: 'PPPSOL',
        color: Colors.blue.shade900,
      );
      _localLayers.ensureLayer(
        'imu',
        label: 'IMU',
        color: Colors.cyan.shade800,
      );
    }
    _localLayers.addListener(_handleLocalLayers);
    _mqtt.addListener(_handleMqttUpdate);
    _mqtt.layers.addListener(_handleMqttUpdate);
    final bluetooth = widget.bluetooth;
    if (bluetooth != null) {
      _bluetoothSubscription = bluetooth.ggaStream.listen(_handleLine);
      bluetooth.addListener(_handleBluetoothConnection);
    }
    // 安卓实时数据由蓝牙提供，不启动桌面串口的数据订阅。
    if (widget.ggaOnly || Platform.isAndroid) return;

    final serialService = SerialService();
    _subscription = serialService.lineStream.listen((line) {
      // GGA is extracted from raw bytes below so clean text lines are not
      // displayed twice. Keep the line stream for PPPSOL and GBGGA.
      if (line.startsWith('\$GNGGA') || line.startsWith('\$GPGGA')) return;
      _handleLine(line);
    });
    final ggaExtractor = GgaSentenceExtractor();
    _ggaSubscription = serialService.dataStream.listen((data) {
      for (final gga in ggaExtractor.add(data)) {
        _handleLine(gga);
      }
    });
    _imuSubscription = ImuDataParser.imuDataStream.listen(_handleImuData);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _ggaSubscription?.cancel();
    _imuSubscription?.cancel();
    _bluetoothSubscription?.cancel();
    widget.bluetooth?.removeListener(_handleBluetoothConnection);
    _localLayers.dispose();
    _localRevision.dispose();
    _mqtt.removeListener(_handleMqttUpdate);
    _mqtt.layers.removeListener(_handleMqttUpdate);
    if (widget.mqtt == null) _mqtt.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _handleBluetoothConnection() {
    final connection = widget.bluetooth!.connection;
    if (!mounted || connection == _bluetoothConnection) return;
    setState(() {
      _bluetoothConnection = connection;
      if (connection == GnssBleConnection.connected) {
        _points.clear();
        _localRevision.value++;
        if (!_mqttMode) {
          _currentInfo = null;
          _currentImuInfo = null;
          _autoCenter = true;
        }
        _selectedIndex = null;
        _isImportMode = false;
      }
    });
  }

  int _getEffectiveImuStatus(ImuData data) {
    int status = data.gnssState ?? 0;
    if ((status < 1 || status > 5) && data.fusionState == 5) {
      return 6;
    }
    return status;
  }

  void _handleImuData(ImuData data) {
    if (_isImportMode || _isImporting) return;
    if (data.utcYear != null && data.utcYear! > 2000 && data.isUtcWholeSecond) {
      if (data.lat != null &&
          data.lon != null &&
          data.lat! != 0 &&
          data.lon! != 0) {
        final gcj02Pos = CoordinateConverter.wgs84ToGcj02(data.lat!, data.lon!);

        final int status = _getEffectiveImuStatus(data);
        final point = PositionHistoryPoint(
          location: gcj02Pos,
          status: status,
          isImu: true,
          type: PointType.imu,
          imuData: data,
        );

        setState(() {
          if (!_mqttMode &&
              _selectedIndex == null &&
              _localLayers.isVisible('imu')) {
            _currentImuInfo = data;
            _currentInfo = null;
          }
          _appendLocalPoint(point);
        });

        if (!_mqttMode &&
            _localLayers.isVisible('imu') &&
            _autoCenter &&
            _selectedIndex == null) {
          _mapController.move(gcj02Pos, _mapController.camera.zoom);
        }
      }
    }
  }

  void _handleLine(String line) {
    if (_isImportMode || _isImporting) return;
    var point = _parseNmeaLine(line);
    if (point == null) return;

    setState(() {
      if (!_mqttMode && _isLocalPointVisible(point) && _selectedIndex == null) {
        if (!point.isImu) {
          _currentInfo = point.posInfo;
          _currentImuInfo = null;
        }
      }
      _appendLocalPoint(point);
    });

    if (!_mqttMode &&
        _isLocalPointVisible(point) &&
        _autoCenter &&
        _selectedIndex == null) {
      _mapController.move(point.location, _mapController.camera.zoom);
    }
  }

  void _appendLocalPoint(PositionHistoryPoint point) {
    _points.add(point);
    if (_points.length > 5000) {
      _points.removeAt(0);
      if (_selectedIndex != null) {
        _selectedIndex = _selectedIndex! > 0 ? _selectedIndex! - 1 : null;
        if (_selectedIndex == null && !_mqttMode) _syncLocalSelection();
      }
    }
    _localRevision.value++;
  }

  PositionHistoryPoint? _parseNmeaLine(String line) =>
      parsePositionLine(line, ggaOnly: widget.ggaOnly);

  bool _isLocalPointVisible(PositionHistoryPoint point) =>
      _localLayers.isVisible(point.type.name);

  void _syncLocalSelection({bool move = false}) {
    PositionHistoryPoint? selected;
    for (final point in _points.reversed) {
      if (_isLocalPointVisible(point)) {
        selected = point;
        break;
      }
    }
    _currentInfo = selected?.posInfo;
    _currentImuInfo = selected?.imuData;
    if (move && selected != null) {
      _mapController.move(selected.location, _mapController.camera.zoom);
    }
  }

  void _handleLocalLayers() {
    if (!mounted || _mqttMode) return;
    setState(() {
      _selectedIndex = null;
      _syncLocalSelection();
    });
  }

  void _syncMqttSelection({bool move = false}) {
    if (_mqttDeviceId == null ||
        !_mqtt.layers.isVisible(_mqttDeviceId!) ||
        _mqtt.tracks[_mqttDeviceId]?.latest == null) {
      _mqttDeviceId = null;
      for (final layer in _mqtt.layers.layers) {
        if (layer.visible && _mqtt.tracks[layer.id]?.latest != null) {
          _mqttDeviceId = layer.id;
          break;
        }
      }
    }
    final fix = _mqtt.tracks[_mqttDeviceId]?.latest;
    final changed = !identical(fix, _mqttShownFix);
    _mqttShownFix = fix;
    _currentInfo = fix?.position.posInfo;
    _currentImuInfo = null;
    if (fix != null && (move || (_autoCenter && changed))) {
      _mapController.move(fix.position.location, _mapController.camera.zoom);
    }
  }

  void _handleMqttUpdate() {
    if (!mounted || !_mqttMode) return;
    setState(() => _syncMqttSelection());
  }

  void _setMqttMode(bool value) {
    setState(() {
      _mqttMode = value;
      _selectedIndex = null;
      if (value) {
        _syncMqttSelection(move: true);
      } else {
        _mqttShownFix = null;
        _syncLocalSelection(move: true);
      }
    });
  }

  void _locateMqttDevice(String id) {
    _mqtt.layers.setVisible(id, true);
    setState(() {
      _mqttDeviceId = id;
      _syncMqttSelection(move: true);
    });
  }

  void _showMqttSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      builder: (_) => MqttConnectionPanel(
        service: _mqtt,
        onReceive: () => _setMqttMode(true),
      ),
    );
  }

  void _showLayers() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height * .8,
      ),
      builder: (context) => AnimatedBuilder(
        animation: Listenable.merge([
          _mqtt,
          _mqtt.layers,
          _localLayers,
          _localRevision,
        ]),
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.layers_outlined),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '图层管理',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭图层管理',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(_mqttMode ? 'MQTT · 按设备配色' : '本地轨迹 · 按定位状态配色'),
              const Text('取消勾选仅隐藏轨迹，数据仍会保留。'),
              MapLayerPanel(
                controller: _mqttMode ? _mqtt.layers : _localLayers,
                pointCounts: _mqttMode
                    ? {
                        for (final entry in _mqtt.tracks.entries)
                          entry.key: entry.value.length,
                      }
                    : {
                        for (final layer in _localLayers.layers)
                          layer.id: _points
                              .where((p) => p.type.name == layer.id)
                              .length,
                      },
                selectedId: _mqttMode ? _mqttDeviceId : null,
                onLocate: _mqttMode
                    ? (id) {
                        _locateMqttDevice(id);
                        Navigator.pop(context);
                      }
                    : null,
                emptyMessage: '等待 MQTT 设备数据，收到有效 GGA 后将自动建立图层。',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getColorForStatus(int status, bool isImu, {PointType? pointType}) {
    if (pointType == PointType.gga) {
      switch (status) {
        case 1:
          return Colors.red.shade700; // SPP
        case 2:
          return Colors.purple.shade600; // DGPS
        case 4:
          return Colors.green.shade800; // RTK FIX
        case 5:
          return Colors.deepOrange.shade700; // RTK FLOAT
        case 6:
          return Colors.blue.shade700; // DR
        default:
          return Colors.grey.shade600;
      }
    }
    if (isImu) {
      switch (status) {
        case 1:
          return Colors.pink.shade700; // SPP
        case 2:
          return Colors.deepPurpleAccent.shade200; // DGPS
        case 4:
          return Colors.cyan.shade800; // RTK FIX
        case 5:
          return Colors.amber.shade900; // RTK FLOAT
        case 6:
          return Colors.lightBlueAccent.shade400; // DR (纯惯导推算)
        default:
          return Colors.blueGrey.shade500;
      }
    } else {
      switch (status) {
        case 2: // SPP with Doppler-pred
          return Colors.grey.shade900;
        case 3: // SPP
          return Colors.yellowAccent.shade700;
        case 4: // PPP
          return Colors.blue.shade900;
        case 5: // SPP with TDCP-pred
          return Colors.greenAccent.shade400;
        default:
          return Colors.grey.shade600;
      }
    }
  }

  void _handleMapPositionChanged(MapCamera camera, bool _) {
    final nextLevel = camera.zoom < 14
        ? 0
        : camera.zoom < 17
        ? 1
        : 2;
    if (nextLevel == _trajectoryDetailLevel) return;
    setState(() => _trajectoryDetailLevel = nextLevel);
  }

  void _toggleGgaAutoFollow() {
    setState(() {
      _autoCenter = !_autoCenter;
      if (!_autoCenter) return;
      _selectedIndex = null;
      if (_mqttMode) {
        _syncMqttSelection(move: true);
      } else {
        _syncLocalSelection(move: true);
      }
    });
  }

  Marker _buildTrajectoryMarker(PositionHistoryPoint point, {Color? color}) {
    final shape = switch (point.type) {
      PointType.gga => _TrajectoryMarkerShape.circle,
      PointType.imu => _TrajectoryMarkerShape.square,
      PointType.pppsol => _TrajectoryMarkerShape.cross,
    };
    final baseSize = switch (point.type) {
      PointType.gga => 6.0,
      PointType.imu => 5.0,
      PointType.pppsol => 7.0,
    };
    final sizeScale = switch (_trajectoryDetailLevel) {
      0 => 0.4,
      1 => 0.65,
      _ => 1.0,
    };
    final fillOpacity = switch (_trajectoryDetailLevel) {
      0 => 0.55,
      1 => 0.72,
      _ => 0.88,
    };
    final showOutline = _trajectoryDetailLevel == 2;
    final size = baseSize * sizeScale;

    return Marker(
      point: point.location,
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TrajectoryPointPainter(
          shape: shape,
          color:
              color ??
              _getColorForStatus(
                point.status,
                point.isImu,
                pointType: point.type,
              ),
          borderColor: showOutline ? Colors.white : Colors.transparent,
          strokeWidth: showOutline ? 0.5 : 0,
          fillOpacity: fillOpacity,
        ),
      ),
    );
  }

  String _getStatusText(int status, bool isImu, {PointType? pointType}) {
    if (pointType == PointType.gga) {
      switch (status) {
        case 1:
          return "SPP (1)";
        case 2:
          return "DGPS (2)";
        case 4:
          return "RTK FIX (4)";
        case 5:
          return "RTK FLOAT (5)";
        case 6:
          return "DR (6)";
        default:
          return "UNKNOWN ($status)";
      }
    }
    if (isImu) {
      switch (status) {
        case 1:
          return "SPP (1)";
        case 2:
          return "DGPS (2)";
        case 4:
          return "RTK FIX (4)";
        case 5:
          return "RTK FLOAT (5)";
        case 6:
          return "DR (6)";
        default:
          return "UNKNOWN ($status)";
      }
    } else {
      switch (status) {
        case 2:
          return "DOPPLER (2)";
        case 3:
          return "SPP (3)";
        case 4:
          return "PPP (4)";
        case 5:
          return "TDCP (5)";
        default:
          return "UNKNOWN ($status)";
      }
    }
  }

  Widget _buildLegendBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final textColor = colorScheme.onSurface;

    Widget legendItem(String label, Color color, _TrajectoryMarkerShape shape) {
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 12,
              child: CustomPaint(
                painter: _TrajectoryPointPainter(
                  shape: shape,
                  color: color,
                  borderColor: textColor.withValues(alpha: 0.55),
                  strokeWidth: 0.8,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: textColor, fontSize: 11)),
          ],
        ),
      );
    }

    Widget legendGroup(
      String title,
      _TrajectoryMarkerShape shape,
      List<(String, Color)> items,
    ) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              color: textColor,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 10),
          for (final item in items) legendItem(item.$1, item.$2, shape),
        ],
      );
    }

    Widget divider() {
      return VerticalDivider(
        width: 16,
        indent: 8,
        endIndent: 8,
        color: textColor.withValues(alpha: 0.25),
      );
    }

    Widget selectedItem() {
      return Padding(
        padding: const EdgeInsets.only(right: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.yellow.shade700, width: 2),
              ),
            ),
            const SizedBox(width: 4),
            Text('当前选中', style: TextStyle(color: textColor, fontSize: 11)),
          ],
        ),
      );
    }

    return Material(
      color: colorScheme.surface,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 40,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                legendGroup('GGA', _TrajectoryMarkerShape.circle, [
                  (
                    'SPP',
                    _getColorForStatus(1, false, pointType: PointType.gga),
                  ),
                  (
                    'DGPS',
                    _getColorForStatus(2, false, pointType: PointType.gga),
                  ),
                  (
                    'RTK FIX',
                    _getColorForStatus(4, false, pointType: PointType.gga),
                  ),
                  (
                    'RTK FLOAT',
                    _getColorForStatus(5, false, pointType: PointType.gga),
                  ),
                ]),
                divider(),
                legendGroup('Fusion', _TrajectoryMarkerShape.square, [
                  (
                    'SPP',
                    _getColorForStatus(1, true, pointType: PointType.imu),
                  ),
                  (
                    'DGPS',
                    _getColorForStatus(2, true, pointType: PointType.imu),
                  ),
                  (
                    'RTK FIX',
                    _getColorForStatus(4, true, pointType: PointType.imu),
                  ),
                  (
                    'RTK FLOAT',
                    _getColorForStatus(5, true, pointType: PointType.imu),
                  ),
                  ('DR', _getColorForStatus(6, true, pointType: PointType.imu)),
                ]),
                divider(),
                legendGroup('PPPSOL', _TrajectoryMarkerShape.cross, [
                  (
                    'DOPPLER',
                    _getColorForStatus(2, false, pointType: PointType.pppsol),
                  ),
                  (
                    'SPP',
                    _getColorForStatus(3, false, pointType: PointType.pppsol),
                  ),
                  (
                    'PPP',
                    _getColorForStatus(4, false, pointType: PointType.pppsol),
                  ),
                  (
                    'TDCP',
                    _getColorForStatus(5, false, pointType: PointType.pppsol),
                  ),
                ]),
                divider(),
                legendItem('未知', Colors.grey, _TrajectoryMarkerShape.circle),
                selectedItem(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _importFile() async {
    if (widget.bluetooth?.isActive == true || _isImporting) return;
    var importStarted = false;
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles();

      if (result != null && result.files.single.path != null) {
        File file = File(result.files.single.path!);
        final int totalBytes = await file.length();
        if (!mounted || widget.bluetooth?.isActive == true) return;
        int processedBytes = 0;
        importStarted = true;
        widget.onImportingChanged?.call(true);

        setState(() {
          _mqttMode = false;
          _mqttShownFix = null;
          _points.clear();
          _autoCenter = false; // Disable auto center during bulk import
          _currentInfo = null;
          _currentImuInfo = null;
          _selectedIndex = null;
          _isImportMode = true;
          _isImporting = true;
          _importProgress = 0.0;
        });

        final parser = widget.ggaOnly ? null : ImuDataParser();
        final nmeaParser = NmeaParser();
        List<PositionHistoryPoint> newPoints = [];
        int? lastSec;
        bool firstPointFound = false;

        int lastYieldTime = DateTime.now().millisecondsSinceEpoch;
        int lastProgressUpdate = DateTime.now().millisecondsSinceEpoch;

        // Parse chunk by chunk to avoid out of memory and UI freeze
        await for (final chunk in file.openRead()) {
          processedBytes += chunk.length;
          parser?.parseData(chunk, (data) {
            if (data.utcYear != null &&
                data.utcYear! > 2000 &&
                data.utcSec != null &&
                data.utcSec != lastSec) {
              if (data.lat != null &&
                  data.lon != null &&
                  data.lat! != 0 &&
                  data.lon! != 0) {
                lastSec = data.utcSec;

                final gcj02Pos = CoordinateConverter.wgs84ToGcj02(
                  data.lat!,
                  data.lon!,
                );

                final int status = _getEffectiveImuStatus(data);
                final point = PositionHistoryPoint(
                  location: gcj02Pos,
                  status: status,
                  isImu: true,
                  type: PointType.imu,
                  imuData: data,
                );

                newPoints.add(point);

                if (!firstPointFound) {
                  firstPointFound = true;
                  // Immediately add first point and center map
                  _points.add(point);
                  if (mounted) {
                    setState(() {
                      _selectedIndex = 0;
                      _mapController.move(
                        point.location,
                        _mapController.camera.zoom,
                      );
                      _currentImuInfo = data;
                    });
                  }
                }
              }
            }
          }, broadcast: false);

          nmeaParser.parseChunk(chunk, (line) {
            var point = _parseNmeaLine(line);
            if (point != null) {
              if (!firstPointFound) {
                firstPointFound = true;
                _points.add(point);
                if (mounted) {
                  setState(() {
                    _selectedIndex = 0;
                    _mapController.move(
                      point.location,
                      _mapController.camera.zoom,
                    );
                    _currentInfo = point.posInfo;
                  });
                }
              } else {
                newPoints.add(point);
              }
            }
          });

          // Update progress every 100ms to avoid too many setState calls
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastProgressUpdate > 100) {
            setState(() {
              _importProgress = totalBytes > 0
                  ? processedBytes / totalBytes
                  : 0.0;
              if (newPoints.isNotEmpty) {
                _points.addAll(newPoints);
                newPoints.clear();
              }
            });
            lastProgressUpdate = now;
          }

          // Yield control to UI thread every 20ms to prevent freezing
          if (now - lastYieldTime > 20) {
            await Future.delayed(Duration.zero);
            lastYieldTime = now;
          }
        }

        setState(() {
          if (newPoints.isNotEmpty) {
            _points.addAll(newPoints);
            newPoints.clear();
          }
          if (_points.length > 50000) {
            // Keep more points for imported files
            _points.removeRange(0, _points.length - 50000);
          }
          _isImporting = false;
          _importProgress = 1.0;
          final firstVisible = _points.indexWhere(_isLocalPointVisible);
          _selectedIndex = firstVisible < 0 ? null : firstVisible;
          final selected = firstVisible < 0 ? null : _points[firstVisible];
          _currentInfo = selected?.posInfo;
          _currentImuInfo = selected?.imuData;
          if (selected != null) {
            _mapController.move(selected.location, _mapController.camera.zoom);
          }
          _localRevision.value++;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件解析完成，共载入 ${_points.length} 个轨迹点')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error importing file: $e');
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgress = 0.0;
        });
      }
    } finally {
      if (importStarted && mounted) widget.onImportingChanged?.call(false);
    }
  }

  void _updateToSelectedEpoch(int index) {
    setState(() {
      _selectedIndex = index;
      _autoCenter = false; // Disable auto center when manually reviewing
      final point = _points[index];
      _mapController.move(point.location, _mapController.camera.zoom);
      if (point.isImu) {
        _currentImuInfo = point.imuData;
        _currentInfo = null;
      } else {
        _currentInfo = point.posInfo;
        _currentImuInfo = null;
      }
    });
  }

  void _clearPoints() {
    if (_mqttMode) {
      _mqtt.clearTracks();
      return;
    }
    setState(() {
      _points.clear();
      _localRevision.value++;
      _currentInfo = null;
      _currentImuInfo = null;
      _selectedIndex = null;
      _isImportMode = false;
      _isImporting = false;
      _importProgress = 0.0;
    });
  }

  List<Widget> _mobileMapActions() => [
    IconButton(
      icon: const Icon(Icons.file_open),
      tooltip: widget.ggaOnly ? '导入 GGA 文件' : '从文件导入IMU定位数据',
      onPressed: _isImporting || widget.bluetooth?.isActive == true
          ? null
          : _importFile,
    ),
    IconButton(
      icon: Icon(
        _autoCenter ? Icons.center_focus_strong : Icons.center_focus_weak,
      ),
      isSelected: _autoCenter,
      tooltip: '自动跟随',
      onPressed: _isImporting ? null : _toggleGgaAutoFollow,
    ),
    IconButton(
      icon: const Icon(Icons.explore_outlined),
      tooltip: '恢复北向（上北下南）',
      onPressed: () => _mapController.rotate(0),
    ),
    if (!_mqttMode && _isImportMode)
      IconButton(
        icon: Icon(_showTimeline ? Icons.timeline : Icons.linear_scale),
        tooltip: _showTimeline ? '隐藏时间轴' : '显示时间轴',
        onPressed: () => setState(() => _showTimeline = !_showTimeline),
      ),
    IconButton(
      icon: const Icon(Icons.layers_outlined),
      tooltip: '图层管理',
      onPressed: _isImporting ? null : _showLayers,
    ),
    PopupMenuButton<String>(
      tooltip: '数据来源',
      enabled: !_isImporting,
      icon: Icon(_mqttMode ? Icons.cloud_download_outlined : Icons.input),
      onSelected: (value) {
        if (value == 'settings') {
          _showMqttSettings();
        } else if (value == 'logs') {
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            showDragHandle: true,
            constraints: const BoxConstraints(maxWidth: 600),
            builder: (context) => SizedBox(
              height: MediaQuery.sizeOf(context).height * .75,
              child: MqttArchivePanel(archive: _mqtt.archive),
            ),
          );
        } else {
          _setMqttMode(value == 'mqtt');
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'local',
          checked: !_mqttMode,
          child: Text(widget.ggaOnly ? '蓝牙 / 离线文件' : '串口 / 离线文件'),
        ),
        CheckedPopupMenuItem(
          value: 'mqtt',
          checked: _mqttMode,
          child: const Text('MQTT 轨迹'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'settings', child: Text('MQTT 连接设置')),
        const PopupMenuItem(value: 'logs', child: Text('MQTT 接收日志')),
      ],
    ),
    IconButton(
      icon: const Icon(Icons.delete_outline),
      tooltip: '清除轨迹',
      onPressed: _isImporting ? null : _clearPoints,
    ),
  ];

  Widget _positionSummary() {
    final info = _currentInfo;
    final colors = Theme.of(context).colorScheme;
    final compact =
        MediaQuery.sizeOf(context).height < 500 ||
        MediaQuery.textScalerOf(context).scale(14) > 20;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow.withValues(alpha: .78),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: .4),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_mqttMode)
                      Tooltip(
                        message: _mqttDeviceId ?? 'MQTT',
                        child: Text(
                          _mqttDeviceId ?? 'MQTT · ${_mqtt.statusLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (_mqttMode && _mqtt.archive.error != null)
                      Text(
                        '日志保存异常，请查看 MQTT 设置',
                        style: TextStyle(fontSize: 11, color: colors.error),
                      ),
                    Row(
                      children: [
                        ExcludeSemantics(
                          child: Icon(
                            info == null
                                ? Icons.location_searching
                                : Icons.gps_fixed,
                            size: 18,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            info == null
                                ? (_mqttMode ? '暂无可见设备位置' : '等待定位数据')
                                : _getStatusText(
                                    info.status,
                                    false,
                                    pointType: info.type,
                                  ),
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      info == null
                          ? (_mqttMode
                                ? '通过数据来源连接，通过图层选择设备'
                                : widget.ggaOnly
                                ? '连接设备或导入 GGA 文件'
                                : '连接主串口或导入定位文件')
                          : '${info.type == PointType.pppsol ? 'PPP' : 'GGA'} UTC: ${info.utcTime}',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.25,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (info != null && !compact) ...[
                      Divider(
                        height: 6,
                        thickness: 1,
                        color: colors.outline.withValues(alpha: .4),
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          _mapReading(
                            Icons.satellite_alt,
                            '${info.satellites}',
                            '卫星',
                          ),
                          _mapReading(
                            Icons.track_changes,
                            info.dop1.toStringAsFixed(2),
                            info.type == PointType.pppsol ? 'DOP 1' : 'HDOP',
                            showLabel: true,
                          ),
                          _mapReading(
                            Icons.height,
                            '${info.altitude.toStringAsFixed(1)} m',
                            '海拔',
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (info != null)
                IconButton(
                  onPressed: _showPositionDetails,
                  tooltip: '查看定位详情',
                  iconSize: 20,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  icon: const Icon(Icons.expand_more),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mapReading(
    IconData icon,
    String value,
    String label, {
    bool showLabel = false,
  }) => Tooltip(
    message: label,
    excludeFromSemantics: showLabel,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Icon(
            icon,
            size: 14,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(width: 3),
        if (showLabel) ...[
          Text(
            '$label:',
            style: TextStyle(
              fontSize: 12,
              height: 1.25,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 3),
        ],
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
            height: 1.25,
          ),
        ),
      ],
    ),
  );

  void _showPositionDetails() {
    final info = _currentInfo;
    final mqttFix = _mqttMode ? _mqttShownFix : null;
    if (info == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '定位详情',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭定位详情',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (mqttFix != null) ...[
                SelectableText('设备：${mqttFix.deviceId}'),
                Text(
                  '发送时间（UTC）：${mqttFix.sendTime?.toIso8601String() ?? '未授时'}',
                ),
                Text(
                  '接收时间（UTC）：${mqttFix.receivedAt.toUtc().toIso8601String()}',
                ),
                const SizedBox(height: 8),
                const Text('GGA 原文'),
                SelectableText(mqttFix.gga),
                const SizedBox(height: 12),
              ],
              Text(
                '${info.type == PointType.pppsol ? 'PPP' : 'GGA'} UTC: ${info.utcTime}',
              ),
              const SizedBox(height: 16),
              MobileStatusChip(
                _getStatusText(info.status, false, pointType: info.type),
                icon: Icons.gps_fixed,
                emphasized: true,
              ),
              const SizedBox(height: 16),
              MobileMetrics(
                children: [
                  MobileMetric(
                    label: '参与定位的卫星',
                    value: '${info.satellites}',
                    icon: Icons.satellite_alt,
                  ),
                  MobileMetric(
                    label: info.type == PointType.pppsol
                        ? '精度因子 DOP 1'
                        : '水平精度因子 HDOP',
                    value: info.dop1.toStringAsFixed(2),
                    icon: Icons.track_changes,
                  ),
                  MobileMetric(
                    label: '海拔',
                    value: '${info.altitude.toStringAsFixed(2)} m',
                    icon: Icons.height,
                  ),
                  if (info.type == PointType.pppsol) ...[
                    MobileMetric(
                      label: '速度',
                      value: '${info.speed.toStringAsFixed(3)} m/s',
                      icon: Icons.speed_outlined,
                    ),
                    MobileMetric(
                      label: '位置精度',
                      value: '${info.posAcc.toStringAsFixed(3)} m',
                      icon: Icons.my_location,
                    ),
                    MobileMetric(
                      label: '速度精度',
                      value: '${info.speedAcc.toStringAsFixed(3)} m/s',
                      icon: Icons.speed,
                    ),
                    MobileMetric(
                      label: 'DOP 2 / DOP 3',
                      value:
                          '${info.dop2.toStringAsFixed(2)} / ${info.dop3.toStringAsFixed(2)}',
                      icon: Icons.track_changes,
                    ),
                  ],
                  if (info.type == PointType.gga &&
                      [2, 4, 5].contains(info.status))
                    MobileMetric(
                      label: '差分龄期',
                      value:
                          '${info.differentialAge?.toStringAsFixed(1) ?? '--'} s',
                      icon: Icons.schedule,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<int> visibleIndices = [];
    for (int i = 0; i < _points.length; i++) {
      final p = _points[i];
      if (_mqttMode || !_isLocalPointVisible(p)) continue;
      visibleIndices.add(i);
    }

    int currentSliderPos = 0;
    if (visibleIndices.isNotEmpty) {
      if (_selectedIndex == null) {
        currentSliderPos = visibleIndices.length - 1;
      } else {
        currentSliderPos = visibleIndices.indexOf(_selectedIndex!);
        if (currentSliderPos == -1) {
          currentSliderPos = visibleIndices.length - 1;
        }
      }
    }

    final compactToolbar =
        widget.ggaOnly || MediaQuery.sizeOf(context).width < 720;
    final actions = _mobileMapActions();
    final mqttTracks = _mqtt.tracks.entries.where(
      (entry) => _mqtt.layers.isVisible(entry.key),
    );
    return Scaffold(
      appBar: AppPageBar(
        title: '定位结果',
        onOpenDrawer: widget.onOpenDrawer,
        bottom: compactToolbar
            ? PreferredSize(
                preferredSize: const Size.fromHeight(52),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: actions.skip(1).toList(),
                  ),
                ),
              )
            : null,
        actions: compactToolbar ? [actions.first] : actions,
      ),
      bottomNavigationBar: widget.ggaOnly || _mqttMode
          ? null
          : _buildLegendBar(),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              // Default center (Wuhan as per example coords)
              initialCenter: const LatLng(30.52845181, 114.35696878),
              initialZoom: 17,
              maxZoom: _maxMapZoom.toDouble(),
              onPositionChanged: _handleMapPositionChanged,
            ),
            children: [
              TileLayer(
                urlTemplate: _amapUrl,
                userAgentPackageName: 'com.example.rtkmanager',
                subdomains: const ['01', '02', '03', '04'], // usually wprd01-04
                maxNativeZoom: _maxMapZoom,
                tileBuilder: (_, tileWidget, _) => ColorFiltered(
                  colorFilter: _mutedMapColorFilter,
                  child: tileWidget,
                ),
              ),
              if (_mqttMode)
                PolylineLayer(
                  polylines: [
                    for (final entry in mqttTracks)
                      if (entry.value.length > 1)
                        Polyline(
                          points: entry.value.points
                              .map((fix) => fix.position.location)
                              .toList(),
                          color: _mqtt.layers[entry.key]!.color,
                          strokeWidth: 2,
                        ),
                  ],
                ),
              MarkerLayer(
                markers: _mqttMode
                    ? [
                        for (final entry in mqttTracks)
                          for (final fix in entry.value.points)
                            _buildTrajectoryMarker(
                              fix.position,
                              color: _mqtt.layers[entry.key]!.color,
                            ),
                        for (final entry in mqttTracks)
                          if (entry.value.latest != null)
                            Marker(
                              point: entry.value.latest!.position.location,
                              width: 48,
                              height: 48,
                              child: IconButton(
                                tooltip: entry.key,
                                onPressed: () => _locateMqttDevice(entry.key),
                                icon: Icon(
                                  Icons.location_on,
                                  color: _mqtt.layers[entry.key]!.color,
                                  size: 28,
                                ),
                              ),
                            ),
                      ]
                    : _points
                          .where(_isLocalPointVisible)
                          .map(_buildTrajectoryMarker)
                          .toList(),
              ),
              if (visibleIndices.isNotEmpty)
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: _points[visibleIndices[currentSliderPos]].location,
                      color: Colors.transparent,
                      borderStrokeWidth: 2,
                      borderColor: Colors.yellow.shade700,
                      radius: 7,
                    ),
                  ],
                ),
            ],
          ),
          if (widget.ggaOnly || _currentImuInfo == null)
            Positioned(top: 12, left: 12, right: 12, child: _positionSummary()),
          if (!widget.ggaOnly && _currentImuInfo != null)
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "UTC: ${_currentImuInfo!.utcHour?.toString().padLeft(2, '0')}:${_currentImuInfo!.utcMin?.toString().padLeft(2, '0')}:${_currentImuInfo!.utcSec?.toString().padLeft(2, '0')}.${_currentImuInfo!.utcFractionText}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Text(
                          "GNSS/Fusion: ",
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        Text(
                          "${_currentImuInfo!.gnssState} / ${_currentImuInfo!.fusionState} (${_getStatusText(_getEffectiveImuStatus(_currentImuInfo!), true, pointType: PointType.imu).replaceAll('\n', ' ')})",
                          style: TextStyle(
                            color: _getColorForStatus(
                              _getEffectiveImuStatus(_currentImuInfo!),
                              true,
                              pointType: PointType.imu,
                            ),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Speed: ${sqrt((_currentImuInfo!.ve ?? 0) * (_currentImuInfo!.ve ?? 0) + (_currentImuInfo!.vn ?? 0) * (_currentImuInfo!.vn ?? 0) + (_currentImuInfo!.vu ?? 0) * (_currentImuInfo!.vu ?? 0)).toStringAsFixed(3)} m/s",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Euler: ${_currentImuInfo!.pitch?.toStringAsFixed(2)}, ${_currentImuInfo!.roll?.toStringAsFixed(2)}, ${_currentImuInfo!.yaw?.toStringAsFixed(2)}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Acc: ${_currentImuInfo!.ax?.toStringAsFixed(3)}, ${_currentImuInfo!.ay?.toStringAsFixed(3)}, ${_currentImuInfo!.az?.toStringAsFixed(3)}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Gyro: ${_currentImuInfo!.wx?.toStringAsFixed(3)}, ${_currentImuInfo!.wy?.toStringAsFixed(3)}, ${_currentImuInfo!.wz?.toStringAsFixed(3)}",
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (!_mqttMode &&
              visibleIndices.isNotEmpty &&
              _showTimeline &&
              _isImportMode)
            Positioned(
              bottom: widget.ggaOnly ? 12 : 20,
              left: widget.ggaOnly ? 12 : 20,
              right: widget.ggaOnly ? 12 : 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 2.0,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6.0,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14.0,
                          ),
                        ),
                        child: Slider(
                          value: currentSliderPos.toDouble(),
                          min: 0,
                          max: visibleIndices.isEmpty
                              ? 1.0
                              : (visibleIndices.length - 1).toDouble(),
                          onChanged: visibleIndices.length <= 1
                              ? null
                              : (value) {
                                  _updateToSelectedEpoch(
                                    visibleIndices[value.toInt()],
                                  );
                                },
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.chevron_left,
                        color: Colors.white,
                        size: 20,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(
                        minWidth: widget.ggaOnly ? 48 : 28,
                        minHeight: widget.ggaOnly ? 48 : 28,
                      ),
                      onPressed: () {
                        if (visibleIndices.isEmpty) return;
                        if (currentSliderPos > 0) {
                          _updateToSelectedEpoch(
                            visibleIndices[currentSliderPos - 1],
                          );
                        }
                      },
                      tooltip: '上一历元',
                    ),
                    Text(
                      '${currentSliderPos + 1} / ${visibleIndices.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.chevron_right,
                        color: Colors.white,
                        size: 20,
                      ),
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(
                        minWidth: widget.ggaOnly ? 48 : 28,
                        minHeight: widget.ggaOnly ? 48 : 28,
                      ),
                      onPressed: () {
                        if (visibleIndices.isEmpty) return;
                        if (currentSliderPos < visibleIndices.length - 1) {
                          _updateToSelectedEpoch(
                            visibleIndices[currentSliderPos + 1],
                          );
                        }
                      },
                      tooltip: '下一历元',
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.skip_next,
                        color: Colors.white,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _selectedIndex = null;
                          if (visibleIndices.isNotEmpty) {
                            final point = _points[visibleIndices.last];
                            if (point.isImu) {
                              _currentImuInfo = point.imuData;
                              _currentInfo = null;
                            } else {
                              _currentInfo = point.posInfo;
                              _currentImuInfo = null;
                            }
                            if (_autoCenter) {
                              _mapController.move(
                                point.location,
                                _mapController.camera.zoom,
                              );
                            }
                          }
                        });
                      },
                      tooltip: '回到最新',
                    ),
                  ],
                ),
              ),
            ),
          // Import progress bar overlay at the bottom
          if (_isImporting)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(8),
                    topRight: Radius.circular(8),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.ggaOnly ? '正在导入 GGA 数据...' : '正在导入IMU数据...',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _importProgress,
                        minHeight: 6,
                        backgroundColor: Colors.grey[700],
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.greenAccent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${(_importProgress * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum _TrajectoryMarkerShape { circle, square, cross }

class _TrajectoryPointPainter extends CustomPainter {
  final _TrajectoryMarkerShape shape;
  final Color color;
  final Color borderColor;
  final double strokeWidth;
  final double fillOpacity;

  const _TrajectoryPointPainter({
    required this.shape,
    required this.color,
    required this.borderColor,
    this.strokeWidth = 0.8,
    this.fillOpacity = 0.88,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    final path = ui.Path();

    switch (shape) {
      case _TrajectoryMarkerShape.circle:
        path.addOval(rect);
      case _TrajectoryMarkerShape.square:
        path.addRect(rect);
      case _TrajectoryMarkerShape.cross:
        final centerX = size.width / 2;
        final centerY = size.height / 2;
        final halfBarWidth = size.shortestSide * 0.14;
        path
          ..moveTo(centerX - halfBarWidth, inset)
          ..lineTo(centerX + halfBarWidth, inset)
          ..lineTo(centerX + halfBarWidth, centerY - halfBarWidth)
          ..lineTo(size.width - inset, centerY - halfBarWidth)
          ..lineTo(size.width - inset, centerY + halfBarWidth)
          ..lineTo(centerX + halfBarWidth, centerY + halfBarWidth)
          ..lineTo(centerX + halfBarWidth, size.height - inset)
          ..lineTo(centerX - halfBarWidth, size.height - inset)
          ..lineTo(centerX - halfBarWidth, centerY + halfBarWidth)
          ..lineTo(inset, centerY + halfBarWidth)
          ..lineTo(inset, centerY - halfBarWidth)
          ..lineTo(centerX - halfBarWidth, centerY - halfBarWidth)
          ..close();
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: fillOpacity)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );
  }

  @override
  bool shouldRepaint(covariant _TrajectoryPointPainter oldDelegate) {
    return shape != oldDelegate.shape ||
        color != oldDelegate.color ||
        borderColor != oldDelegate.borderColor ||
        strokeWidth != oldDelegate.strokeWidth ||
        fillOpacity != oldDelegate.fillOpacity;
  }
}

class NmeaParser {
  List<int> _buffer = [];

  void parseChunk(List<int> chunk, void Function(String) onLine) {
    _buffer.addAll(chunk);

    int startIndex = 0;
    while (startIndex < _buffer.length) {
      int dollarIndex = _buffer.indexOf(36, startIndex); // Find '$'
      if (dollarIndex == -1) {
        break;
      }

      int nlIndex = _buffer.indexOf(10, dollarIndex); // Find '\n'
      if (nlIndex == -1) {
        _buffer = _buffer.sublist(dollarIndex);
        if (_buffer.length > 4096) {
          int latestDollar = _buffer.lastIndexOf(36);
          if (latestDollar > 0) {
            _buffer = _buffer.sublist(latestDollar);
          } else {
            _buffer.clear();
          }
        }
        return;
      }

      int lastDollarIndex = _buffer.lastIndexOf(36, nlIndex);

      int endIndex = nlIndex;
      if (endIndex > lastDollarIndex && _buffer[endIndex - 1] == 13) {
        endIndex--; // Strip '\r'
      }

      if (endIndex - lastDollarIndex < 1024) {
        try {
          String line = String.fromCharCodes(
            _buffer.sublist(lastDollarIndex, endIndex),
          );
          if (line.isNotEmpty && line.startsWith('\$')) {
            onLine(line);
          }
        } catch (_) {}
      }

      startIndex = nlIndex + 1;
    }

    _buffer.clear();
  }
}
