import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'serial_service.dart';
import 'ntrip_service.dart';
import 'app_ui.dart';
import 'imu_data_parser.dart';
import 'gga_sentence_extractor.dart';

class RtkConfigPage extends StatefulWidget {
  final VoidCallback onOpenDrawer;
  final List<String> Function()? listSerialPorts;

  const RtkConfigPage({
    super.key,
    required this.onOpenDrawer,
    this.listSerialPorts,
  });

  @override
  State<RtkConfigPage> createState() => _RtkConfigPageState();
}

class _RtkConfigPageState extends State<RtkConfigPage> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isPasswordVisible = false;

  List<String> _mountPoints = [];
  String? _selectedMountPoint;

  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();

  StreamSubscription? _serialSubscription;
  StreamSubscription? _ntripDataSubscription;
  StreamSubscription? _ntripLogSubscription;

  final SerialService _serialService = SerialService();
  final NtripService _ntripService = NtripService();

  bool _autoReconnectEnabled = false;
  Timer? _reconnectTimer;

  // GGA Source Configuration
  String _ggaSourcePort = "主串口";
  int _ggaSourceBaudRate = 115200;
  SerialService? _ggaSerialService;
  bool _ownGgaService = false;

  // Output Configuration
  bool _outputToFile = false;

  // For new serial port
  List<String> _availablePorts = [];
  final List<SerialOutputItem> _outputSerialItems = [];
  final List<int> _baudRates = [
    9600,
    19200,
    38400,
    57600,
    115200,
    230400,
    460800,
    921600,
  ];

  // For file output
  String? _outputFilePath;
  IOSink? _fileSink;

  @override
  void initState() {
    super.initState();
    _refreshPorts();
    _ipController.addListener(() {
      _ntripService.setHasConfig(_ipController.text.isNotEmpty);
    });

    _ntripLogSubscription = _ntripService.logStream.listen((log) {
      _addLog(log, timestamp: false); // Log already has timestamp
    });

    _ntripService.addListener(_onNtripStateChanged);
  }

  void _onNtripStateChanged() {
    if (mounted) setState(() {});
    if (!_ntripService.isConnected && _autoReconnectEnabled) {
      // Simple debounce or check if we should reconnect
      if (_reconnectTimer == null || !_reconnectTimer!.isActive) {
        _addLog("连接断开，正在自动重连...");
        _reconnectTimer = Timer(const Duration(seconds: 3), () {
          if (mounted && _autoReconnectEnabled && !_ntripService.isConnected) {
            _connect();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _disconnect(intentional: true);
    _ipController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _logScrollController.dispose();
    _ntripLogSubscription?.cancel();
    _ntripService.removeListener(_onNtripStateChanged);
    super.dispose();
  }

  void _refreshPorts() {
    List<String> ports = [];
    try {
      ports = widget.listSerialPorts?.call() ?? SerialPort.availablePorts;
    } catch (e) {
      _addLog("无法获取串口列表: $e");
    }
    setState(() {
      _availablePorts = ports;
    });
  }

  Future<void> _pickFile() async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: '选择保存 RTCM 数据的文件',
      fileName: 'rtcm_data.bin',
    );

    if (outputFile != null) {
      setState(() {
        _outputFilePath = outputFile;
      });
    }
  }

  void _disconnect({bool intentional = true}) {
    _reconnectTimer?.cancel();
    _ntripService.disconnect();
    _serialSubscription?.cancel();
    _serialSubscription = null;
    _ntripDataSubscription?.cancel();
    _ntripDataSubscription = null;

    if (_ownGgaService && _ggaSerialService != null) {
      _ggaSerialService!.close();
      _ggaSerialService = null;
      _ownGgaService = false;
    }

    // Close output resources
    for (var item in _outputSerialItems) {
      item.serialPort?.close();
      item.serialPort = null;
      item.sharedService = null;
    }

    if (_fileSink != null) {
      final sink = _fileSink!;
      _fileSink = null;
      sink.flush().then((_) => sink.close()).catchError((e) {
        debugPrint('Error closing file sink: $e');
      });
    }
  }

  void _addLog(String message, {bool timestamp = true}) {
    setState(() {
      if (timestamp) {
        _logs.add("[${DateTime.now().toString().split('.')[0]}] $message");
      } else {
        _logs.add(message);
      }
      // Limit log size to save memory on Raspberry Pi
      if (_logs.length > 100) {
        _logs.removeAt(0);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(
          _logScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  Future<void> _getMountPoints() async {
    if (_ipController.text.isEmpty || _portController.text.isEmpty) {
      _addLog("错误: 请输入 IP 和端口");
      return;
    }

    String ip = _ipController.text;
    int port = int.tryParse(_portController.text) ?? 2101;

    List<String> mps = await _ntripService.getMountPoints(ip, port);

    if (mps.isNotEmpty) {
      setState(() {
        _mountPoints = mps;
        if (_selectedMountPoint == null ||
            !_mountPoints.contains(_selectedMountPoint)) {
          _selectedMountPoint = mps.first;
        }
      });
    }
  }

  Future<void> _connect() async {
    _reconnectTimer?.cancel();

    if (_ntripService.isConnected) {
      _disconnect(intentional: true);
      return;
    }

    if (_selectedMountPoint == null) {
      _addLog("错误: 请先选择挂载点");
      return;
    }

    if (_ipController.text.isEmpty || _portController.text.isEmpty) {
      _addLog("错误: 请输入 IP 和端口");
      return;
    }

    // Setup GGA Source Service
    if (_ggaSourcePort == "主串口") {
      _ggaSerialService = _serialService;
      _ownGgaService = false;
    } else if (_ggaSourcePort == "从IMU解析") {
      _ggaSerialService = null;
      _ownGgaService = false;
    } else {
      var existingService = SerialService.getActiveService(_ggaSourcePort);
      if (existingService != null && existingService.isOpen) {
        _ggaSerialService = existingService;
        _ownGgaService = false;
      } else {
        _ggaSerialService = SerialService.create();
        try {
          _ggaSerialService!.open(
            _ggaSourcePort,
            _ggaSourceBaudRate,
            false,
            false,
          );
          if (!_ggaSerialService!.isOpen) {
            _addLog("错误: 无法打开 GGA 来源串口 $_ggaSourcePort");
            _ggaSerialService = null;
            return;
          }
          _ownGgaService = true;
          _addLog("已打开 GGA 来源串口: $_ggaSourcePort");
        } catch (e) {
          _addLog("错误: 打开 GGA 来源串口失败 $_ggaSourcePort $e");
          _ggaSerialService = null;
          return;
        }
      }
    }

    // Setup Output Destination
    for (var item in _outputSerialItems) {
      if (item.portName == null) continue;

      // Check if port is already open by SerialService
      var existingService = SerialService.getActiveService(item.portName!);
      if (existingService != null && existingService.isOpen) {
        item.sharedService = existingService;
        _addLog("使用已打开的串口: ${item.portName}");
        continue;
      }

      try {
        item.serialPort = SerialPort(item.portName!);
        if (!item.serialPort!.openReadWrite()) {
          _addLog("错误: 无法打开输出串口 ${item.portName}");
          item.serialPort = null;
          continue;
        }
        SerialPortConfig config = item.serialPort!.config;
        config.baudRate = item.baudRate;
        item.serialPort!.config = config;
        _addLog("已打开输出串口: ${item.portName}");
      } catch (e) {
        _addLog("错误: 打开输出串口失败 ${item.portName} $e");
        item.serialPort = null;
      }
    }

    if (_outputToFile) {
      if (_outputFilePath == null) {
        _addLog("错误: 请选择输出文件路径");
        return;
      }
      try {
        File file = File(_outputFilePath!);
        _fileSink = file.openWrite(mode: FileMode.append);
        _addLog("已打开输出文件: $_outputFilePath");
      } catch (e) {
        _addLog("错误: 无法打开输出文件 $e");
        return;
      }
    }

    String ip = _ipController.text;
    int port = int.tryParse(_portController.text) ?? 2101;
    String user = _userController.text;
    String password = _passwordController.text;

    try {
      await _ntripService.connect(
        ip,
        port,
        _selectedMountPoint!,
        user,
        password,
      );

      // Start listening to data
      _ntripDataSubscription = _ntripService.dataStream.listen((data) {
        // Route Data
        try {
          for (var item in _outputSerialItems) {
            if (item.sharedService != null) {
              item.sharedService!.write(data);
            } else {
              item.serialPort?.write(data);
            }
          }
          if (_outputToFile) {
            _fileSink?.add(data);
          }
        } catch (e) {
          _addLog("写入数据失败: $e");
        }
      });

      _startForwardingGNGGA();
    } catch (e) {
      // Logged in service
    }
  }

  String _generateGga(ImuData data) {
    if (data.lat == null || data.lon == null) return "";

    // Time: hhmmss.ss
    String hh = (data.utcHour ?? 0).toString().padLeft(2, '0');
    String mm = (data.utcMin ?? 0).toString().padLeft(2, '0');
    String ss = (data.utcSec ?? 0).toString().padLeft(2, '0');
    String mss = ((data.utcSubsecondUsec ?? 0) ~/ 10000).toString().padLeft(
      2,
      '0',
    );
    String timeStr = "$hh$mm$ss.$mss";

    // Lat: ddmm.mmmmmmm
    double lat = data.lat!.abs();
    int latDeg = lat.floor();
    double latMin = (lat - latDeg) * 60;
    String latStr =
        "${latDeg.toString().padLeft(2, '0')}${latMin.toStringAsFixed(7).padLeft(10, '0')}";
    String nsStr = data.lat! >= 0 ? "N" : "S";

    // Lon: dddmm.mmmmmmm
    double lon = data.lon!.abs();
    int lonDeg = lon.floor();
    double lonMin = (lon - lonDeg) * 60;
    String lonStr =
        "${lonDeg.toString().padLeft(3, '0')}${lonMin.toStringAsFixed(7).padLeft(10, '0')}";
    String ewStr = data.lon! >= 0 ? "E" : "W";

    int status = data.gnssState ?? 0;
    if ((status < 1 || status > 5) && data.fusionState == 5) {
      status = 6; // 纯惯导推算 (Dead Reckoning)
    } else if (status == 0) {
      status = 6; // 兜底处理
    }

    int sats = 12;
    String hdop = "1.0";
    String alt = (data.alt ?? 0.0).toStringAsFixed(3);

    String core =
        "GNGGA,$timeStr,$latStr,$nsStr,$lonStr,$ewStr,$status,$sats,$hdop,$alt,M,0.0,M,,";

    int checksum = 0;
    for (int i = 0; i < core.length; i++) {
      checksum ^= core.codeUnitAt(i);
    }
    String chkStr = checksum.toRadixString(16).toUpperCase().padLeft(2, '0');

    return "\$$core*$chkStr\r\n";
  }

  void _startForwardingGNGGA() {
    _serialSubscription?.cancel();

    if (_ggaSourcePort == "从IMU解析") {
      String lastSentTime = "";
      _serialSubscription = ImuDataParser.imuDataStream.listen((data) {
        if (data.lat != null &&
            data.lon != null &&
            data.lat! != 0 &&
            data.lon! != 0) {
          // 只发送整秒
          if (data.isUtcWholeSecond) {
            String timeStr = "${data.utcHour}${data.utcMin}${data.utcSec}";
            if (timeStr != lastSentTime) {
              lastSentTime = timeStr;
              String gga = _generateGga(data);
              _ntripService.sendGNGGA(gga);
            }
          }
        }
      });
      _addLog("开始监听 IMU 解码出的位置数据并上传 GGA ...");
      return;
    }

    if (_ggaSerialService == null || !_ggaSerialService!.isOpen) {
      _addLog("警告: GGA来源串口未打开，无法获取 GNGGA 数据");
      return;
    }

    String lastSentTime = "";
    final ggaExtractor = GgaSentenceExtractor();

    _serialSubscription = _ggaSerialService!.dataStream.listen((data) {
      for (final gga in ggaExtractor.add(data)) {
        if (gga.contains("*")) {
          List<String> parts = gga.split(',');
          if (parts.length > 1) {
            String timeStr = parts[1];
            // 只发送整秒，并且避免同一秒内发送多次（比如同时收到 GPGGA 和 GNGGA）
            if (timeStr.isNotEmpty &&
                timeStr != lastSentTime &&
                (!timeStr.contains('.') ||
                    RegExp(r'\.0+$').hasMatch(timeStr))) {
              lastSentTime = timeStr;
              _ntripService.sendGNGGA(gga);
            }
          }
        }
      }
    });
    _addLog("开始监听串口 GNGGA 数据并上传...");
  }

  Widget _buildConfigCard() => AppSectionCard(
    title: 'NTRIP 连接配置',
    icon: Icons.settings_input_antenna,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppFieldPair(
          first: TextField(
            controller: _ipController,
            decoration: InputDecoration(
              labelText: 'IP 地址 / 域名',
              suffixIcon: PopupMenuButton<String>(
                tooltip: '常用地址',
                icon: const Icon(Icons.arrow_drop_down),
                onSelected: (value) => _ipController.text = value,
                itemBuilder: (_) =>
                    [
                          '116.211.238.25',
                          '203.107.45.154',
                          'sdk.pnt.10086.cn',
                          '103.143.19.54',
                          'rtk.huacenav.com',
                          '140.143.212.42',
                          'ntrip.gnsslab.cn',
                        ]
                        .map(
                          (value) =>
                              PopupMenuItem(value: value, child: Text(value)),
                        )
                        .toList(),
              ),
            ),
          ),
          second: TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '端口',
              suffixIcon: PopupMenuButton<String>(
                tooltip: '常用端口',
                icon: const Icon(Icons.arrow_drop_down),
                onSelected: (value) => _portController.text = value,
                itemBuilder: (_) => ['2101', '8001', '8002', '8003']
                    .map(
                      (value) =>
                          PopupMenuItem(value: value, child: Text(value)),
                    )
                    .toList(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        AppFieldPair(
          first: TextField(
            controller: _userController,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          second: TextField(
            controller: _passwordController,
            obscureText: !_isPasswordVisible,
            decoration: InputDecoration(
              labelText: '密码',
              suffixIcon: IconButton(
                tooltip: _isPasswordVisible ? '隐藏密码' : '显示密码',
                icon: Icon(
                  _isPasswordVisible ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _isPasswordVisible = !_isPasswordVisible),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: _selectedMountPoint,
          decoration: const InputDecoration(labelText: '挂载点'),
          items: _mountPoints
              .map((mp) => DropdownMenuItem(value: mp, child: Text(mp)))
              .toList(),
          onChanged: (value) => setState(() => _selectedMountPoint = value),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _getMountPoints,
            icon: const Icon(Icons.refresh),
            label: const Text('获取列表'),
          ),
        ),
        const MobileSectionTitle('GGA 来源', icon: Icons.my_location),
        AppFieldPair(
          first: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue:
                ['主串口', '从IMU解析', ..._availablePorts].contains(_ggaSourcePort)
                ? _ggaSourcePort
                : '主串口',
            decoration: const InputDecoration(labelText: 'GGA来源串口'),
            items: {'主串口', '从IMU解析', ..._availablePorts}
                .map(
                  (port) => DropdownMenuItem(
                    value: port,
                    child: Text(port, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) setState(() => _ggaSourcePort = value);
            },
          ),
          second: _baudField(
            _ggaSourceBaudRate,
            (_ggaSourcePort == '主串口' || _ggaSourcePort == '从IMU解析')
                ? null
                : (value) => setState(() => _ggaSourceBaudRate = value),
          ),
        ),
        const MobileSectionTitle('数据输出', icon: Icons.output_outlined),
        for (final (index, item) in _outputSerialItems.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              children: [
                AppFieldPair(
                  first: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: item.portName,
                    decoration: const InputDecoration(labelText: '串口'),
                    items: _availablePorts
                        .map(
                          (port) => DropdownMenuItem(
                            value: port,
                            child: Text(port, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() => item.portName = value),
                  ),
                  second: _baudField(
                    item.baudRate,
                    (value) => setState(() => item.baudRate = value),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: '删除输出串口',
                    icon: const Icon(Icons.delete),
                    onPressed: () =>
                        setState(() => _outputSerialItems.removeAt(index)),
                  ),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () =>
                  setState(() => _outputSerialItems.add(SerialOutputItem())),
              icon: const Icon(Icons.add),
              label: const Text('添加输出串口'),
            ),
            IconButton(
              onPressed: _refreshPorts,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新串口列表',
            ),
          ],
        ),
        CheckboxListTile(
          title: const Text('输出到文件'),
          value: _outputToFile,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (value) => setState(() => _outputToFile = value ?? false),
        ),
        if (_outputToFile) ...[
          SelectableText(
            _outputFilePath ?? '未选择文件',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('选择文件'),
          ),
        ],
        const Divider(height: 24),
        SwitchListTile(
          title: const Text('自动重连'),
          contentPadding: EdgeInsets.zero,
          value: _autoReconnectEnabled,
          onChanged: (value) => setState(() => _autoReconnectEnabled = value),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _connect,
          icon: Icon(_ntripService.isConnected ? Icons.link_off : Icons.link),
          label: Text(_ntripService.isConnected ? '断开连接' : '连接 NTRIP'),
        ),
      ],
    ),
  );

  Widget _baudField(int value, ValueChanged<int>? onChanged) =>
      DropdownButtonFormField<int>(
        isExpanded: true,
        initialValue: value,
        decoration: const InputDecoration(labelText: '波特率'),
        items: _baudRates
            .map((rate) => DropdownMenuItem(value: rate, child: Text('$rate')))
            .toList(),
        onChanged: onChanged == null
            ? null
            : (value) {
                if (value != null) onChanged(value);
              },
      );

  Widget _buildLogContainer() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey),
      ),
      child: ListView.builder(
        controller: _logScrollController,
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          return Text(
            _logs[index],
            style: const TextStyle(
              color: Colors.greenAccent,
              fontFamily: 'SourceCodePro',
              fontSize: 12,
              fontFamilyFallback: ['SourceHanSansHWSC'],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppPageBar(title: 'RTK 配置', onOpenDrawer: widget.onOpenDrawer),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: AppColumns(
        primaryFlex: 3,
        secondaryFlex: 2,
        primary: _buildConfigCard(),
        secondary: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MobileHero(
              title: '连接差分服务',
              description: '配置 NTRIP 服务与 GGA 来源，将差分数据转发至串口或保存到文件。',
              icon: Icons.settings_input_antenna,
              status: MobileStatusChip(
                _ntripService.isConnected ? 'NTRIP 已连接' : 'NTRIP 未连接',
                icon: _ntripService.isConnected ? Icons.link : Icons.link_off,
                emphasized: _ntripService.isConnected,
              ),
            ),
            const SizedBox(height: 16),
            AppSectionCard(
              title: '运行日志',
              icon: Icons.receipt_long_outlined,
              child: SizedBox(height: 220, child: _buildLogContainer()),
            ),
          ],
        ),
      ),
    ),
  );
}

class SerialOutputItem {
  String? portName;
  int baudRate;
  SerialPort? serialPort;
  SerialService? sharedService;

  SerialOutputItem({this.portName, this.baudRate = 115200});
}
