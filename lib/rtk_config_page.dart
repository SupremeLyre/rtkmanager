import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'serial_service.dart';
import 'ntrip_service.dart';

class RtkConfigPage extends StatefulWidget {
  final VoidCallback onOpenDrawer;

  const RtkConfigPage({super.key, required this.onOpenDrawer});

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
    setState(() {
      _availablePorts = SerialPort.availablePorts;
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

  Color _getStatusColor() {
    if (_ipController.text.isEmpty) {
      return Colors.grey;
    }
    return _ntripService.isConnected ? Colors.green : Colors.red;
  }

  void _disconnect({bool intentional = true}) {
    _reconnectTimer?.cancel();
    _ntripService.disconnect();
    _serialSubscription?.cancel();
    _serialSubscription = null;
    _ntripDataSubscription?.cancel();
    _ntripDataSubscription = null;

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

  void _startForwardingGNGGA() {
    if (!_serialService.isOpen) {
      _addLog("警告: 串口未打开，无法获取 GNGGA 数据");
    }

    _serialSubscription = _serialService.lineStream.listen((line) {
      if (line.startsWith("\$GNGGA")) {
        if (line.contains("*")) {
          _ntripService.sendGNGGA(line);
        }
      }
    });
    _addLog("开始监听串口 GNGGA 数据并上传...");
  }

  Widget _buildConfigCard() {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NTRIP 连接配置',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _ipController,
                    style: const TextStyle(fontSize: 14),
                    decoration: const InputDecoration(
                      labelText: 'IP 地址 / 域名',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _portController,
                    style: const TextStyle(fontSize: 14),
                    decoration: const InputDecoration(
                      labelText: '端口',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _userController,
                    style: const TextStyle(fontSize: 14),
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _passwordController,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      labelText: '密码',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _isPasswordVisible
                              ? Icons.visibility
                              : Icons.visibility_off,
                          size: 18,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          setState(() {
                            _isPasswordVisible = !_isPasswordVisible;
                          });
                        },
                      ),
                    ),
                    obscureText: !_isPasswordVisible,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedMountPoint,
                    style: const TextStyle(fontSize: 14, color: Colors.black),
                    decoration: const InputDecoration(
                      labelText: '挂载点',
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                    items: _mountPoints.map((mp) {
                      return DropdownMenuItem(
                        value: mp,
                        child: Text(mp, style: const TextStyle(fontSize: 14)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedMountPoint = value;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  height: 36,
                  child: ElevatedButton(
                    onPressed: _getMountPoints,
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                    child: const Text('获取列表', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              "数据输出方式:",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            Column(
              children: [
                ..._outputSerialItems.asMap().entries.map((entry) {
                  int index = entry.key;
                  SerialOutputItem item = entry.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4.0),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<String>(
                            value: item.portName,
                            style: const TextStyle(fontSize: 14, color: Colors.black),
                            decoration: const InputDecoration(
                              labelText: '串口',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                            items: _availablePorts.map((port) {
                              return DropdownMenuItem(
                                value: port,
                                child: Text(port, style: const TextStyle(fontSize: 14, color: Colors.black)),
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() {
                                item.portName = value;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          flex: 1,
                          child: DropdownButtonFormField<int>(
                            value: item.baudRate,
                            style: const TextStyle(fontSize: 14, color: Colors.black),
                            decoration: const InputDecoration(
                              labelText: '波特率',
                              border: OutlineInputBorder(),
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                            items: _baudRates.map((rate) {
                              return DropdownMenuItem(
                                value: rate,
                                child: Text(rate.toString(), style: const TextStyle(fontSize: 14, color: Colors.black)),
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() {
                                item.baudRate = value!;
                              });
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete,
                            color: Colors.red,
                          ),
                          iconSize: 20,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            setState(() {
                              _outputSerialItems.removeAt(index);
                            });
                          },
                        ),
                      ],
                    ),
                  );
                }),
                Row(
                  children: [
                    SizedBox(
                      height: 32,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _outputSerialItems.add(SerialOutputItem());
                          });
                        },
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text("添加输出串口", style: TextStyle(fontSize: 13)),
                        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      iconSize: 20,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _refreshPorts,
                      tooltip: '刷新串口列表',
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 32,
                  child: CheckboxListTile(
                    title: const Text('输出到文件', style: TextStyle(fontSize: 14)),
                    value: _outputToFile,
                    onChanged: (value) {
                      setState(() {
                        _outputToFile = value ?? false;
                      });
                    },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ),
                if (_outputToFile)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 16.0,
                      bottom: 4.0,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _outputFilePath ?? '未选择文件',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          height: 28,
                          child: ElevatedButton(
                            onPressed: _pickFile,
                            style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                            child: const Text('选择文件', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Row(
                  children: [
                    SizedBox(
                      height: 24,
                      child: Switch(
                        value: _autoReconnectEnabled,
                        onChanged: (value) {
                          setState(() {
                            _autoReconnectEnabled = value;
                          });
                        },
                      ),
                    ),
                    const Text("自动重连", style: TextStyle(fontSize: 14)),
                  ],
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: ElevatedButton.icon(
                      onPressed: _connect,
                      icon: Icon(
                        _ntripService.isConnected
                            ? Icons.link_off
                            : Icons.link,
                        size: 18,
                      ),
                      label: Text(
                        _ntripService.isConnected
                            ? '断开 NTRIP'
                            : '连接 NTRIP',
                        style: const TextStyle(fontSize: 14),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 0),
                        backgroundColor: _ntripService.isConnected
                            ? Colors.red
                            : Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogContainer() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(4),
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 36,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          iconSize: 20,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: widget.onOpenDrawer,
        ),
        title: const Text(
          'RTK 配置',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: _getStatusColor(),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          bool isSmallHeight = constraints.maxHeight < 500;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildConfigCard(),
                const SizedBox(height: 20),
                const Text(
                  '运行日志',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: isSmallHeight ? 120 : 200,
                  child: _buildLogContainer(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class SerialOutputItem {
  String? portName;
  int baudRate;
  SerialPort? serialPort;
  SerialService? sharedService;

  SerialOutputItem({this.portName, this.baudRate = 115200});
}
