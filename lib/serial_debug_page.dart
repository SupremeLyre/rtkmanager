import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'serial_service.dart';
import 'ntrip_service.dart';
import 'imu_data_parser.dart';
import 'app_ui.dart';

class SerialDebugPage extends StatefulWidget {
  final VoidCallback? onOpenDrawer;

  const SerialDebugPage({super.key, this.onOpenDrawer});

  @override
  State<SerialDebugPage> createState() => _SerialDebugPageState();
}

class _SerialDebugPageState extends State<SerialDebugPage>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final List<SerialTabItem> _tabs = [];
  final NtripService _ntripService = NtripService();
  bool _isGlobalSaving = false;

  Timer? _dataRateTimer;
  int _lastRxBytes = 0;
  int _lastTxBytes = 0;
  int _rxDataRate = 0;
  int _txDataRate = 0;

  @override
  void initState() {
    super.initState();
    _ntripService.addListener(_onNtripStateChanged);

    // Add default tab (Main)
    _tabs.add(
      SerialTabItem(
        title: "主串口",
        service: SerialService(), // Singleton
        key: GlobalKey<SerialDebugContentState>(),
        isClosable: false,
      ),
    );

    _tabController = TabController(length: _tabs.length, vsync: this);

    _tabController.addListener(_onTabChanged);

    _dataRateTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _calculateDataRate(),
    );
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      // Reset counters when switching tabs
      final service = _tabs[_tabController.index].service;
      _lastRxBytes = service.rxBytes;
      _lastTxBytes = service.txBytes;
      setState(() {
        _rxDataRate = 0;
        _txDataRate = 0;
      });
    }
  }

  void _calculateDataRate() {
    if (!mounted || _tabs.isEmpty) return;

    final int currentIndex = _tabController.index;
    if (currentIndex >= 0 && currentIndex < _tabs.length) {
      final service = _tabs[currentIndex].service;

      final int currentRx = service.rxBytes;
      final int currentTx = service.txBytes;

      setState(() {
        _rxDataRate = currentRx - _lastRxBytes;
        _txDataRate = currentTx - _lastTxBytes;
      });

      _lastRxBytes = currentRx;
      _lastTxBytes = currentTx;
    }
  }

  Future<void> _toggleGlobalSaving() async {
    final bool newState = !_isGlobalSaving;
    final List<String> errors = [];
    int affectedCount = 0;

    for (var tab in _tabs) {
      try {
        if (newState) {
          if (!tab.service.isOpen || tab.service.isSavingToFile) continue;

          final portName = tab.service.currentPortName;
          if (portName == null) continue;

          final filePath = await _buildSerialSaveFilePath(portName);
          await tab.service.startSavingToFile(filePath);
          affectedCount++;
        } else if (tab.service.isSavingToFile) {
          await tab.service.stopSavingToFile();
          affectedCount++;
        }
      } catch (e) {
        errors.add('${tab.title}: $e');
      }
    }

    if (!mounted) return;

    setState(() {
      _isGlobalSaving = newState;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            errors.isEmpty
                ? (newState
                      ? "已开启所有串口保存 ($affectedCount 个串口)"
                      : "已停止所有串口保存 ($affectedCount 个串口)")
                : (newState
                      ? "部分串口保存失败: ${errors.first}"
                      : "部分串口停止保存失败: ${errors.first}"),
          ),
          backgroundColor: errors.isEmpty
              ? (newState ? Colors.green : Colors.orange)
              : Colors.red,
        ),
      );
    }
  }

  void _onNtripStateChanged() {
    if (mounted) setState(() {});
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  void _addTab() {
    setState(() {
      _tabs.add(
        SerialTabItem(
          title: "串口 ${_tabs.length + 1}",
          service: SerialService.create(),
          key: GlobalKey<SerialDebugContentState>(),
          isClosable: true,
        ),
      );
      _updateTabController(initialIndex: _tabs.length - 1);
    });
  }

  void _removeTab(int index) {
    if (!_tabs[index].isClosable) return;

    setState(() {
      _tabs[index].service.close(); // Ensure port is closed
      _tabs.removeAt(index);
      int newIndex = _tabController.index;
      if (newIndex >= _tabs.length) {
        newIndex = _tabs.length - 1;
      }
      _updateTabController(initialIndex: newIndex);
    });
  }

  void _updateTabController({int initialIndex = 0}) {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: initialIndex,
    );
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _dataRateTimer?.cancel();
    _ntripService.removeListener(_onNtripStateChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    // Close all non-singleton services
    for (var tab in _tabs) {
      if (tab.isClosable) {
        tab.service.close();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppPageBar(
      title: '串口调试助手',
      onOpenDrawer: widget.onOpenDrawer,
      actions: [
        IconButton(
          onPressed: _addTab,
          icon: const Icon(Icons.add),
          tooltip: '新建串口连接',
        ),
        IconButton(
          onPressed: _toggleGlobalSaving,
          icon: Icon(_isGlobalSaving ? Icons.save_as : Icons.save_alt),
          tooltip: _isGlobalSaving ? '停止所有保存' : '保存所有数据',
        ),
        const SizedBox(width: 8),
      ],
      bottom: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: _tabs
            .asMap()
            .entries
            .map(
              (entry) => Tab(
                height: 48,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.usb, size: 18),
                    const SizedBox(width: 8),
                    Text(entry.value.title),
                    if (entry.value.isClosable)
                      IconButton(
                        onPressed: () => _removeTab(entry.key),
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: '关闭${entry.value.title}',
                      ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    ),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              MobileStatusChip(
                '接收 ${_formatBytes(_rxDataRate)}/s',
                icon: Icons.south_west,
              ),
              MobileStatusChip(
                '发送 ${_formatBytes(_txDataRate)}/s',
                icon: Icons.north_east,
              ),
              MobileStatusChip(
                _ntripService.isConnected ? 'NTRIP 已连接' : 'NTRIP 未连接',
                icon: Icons.settings_input_antenna,
                emphasized: _ntripService.isConnected,
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: _tabs
                .map(
                  (tab) => SerialDebugContent(
                    key: tab.key,
                    serialService: tab.service,
                    globalSaving: _isGlobalSaving,
                  ),
                )
                .toList(),
          ),
        ),
      ],
    ),
  );
}

class SerialTabItem {
  String title;
  final SerialService service;
  final GlobalKey<SerialDebugContentState> key;
  final bool isClosable;

  SerialTabItem({
    required this.title,
    required this.service,
    required this.key,
    this.isClosable = true,
  });
}

class SerialDebugContent extends StatefulWidget {
  final SerialService serialService;
  final bool globalSaving;

  const SerialDebugContent({
    super.key,
    required this.serialService,
    required this.globalSaving,
  });

  @override
  State<SerialDebugContent> createState() => SerialDebugContentState();
}

class SerialDebugContentState extends State<SerialDebugContent>
    with AutomaticKeepAliveClientMixin {
  List<String> _availablePorts = [];
  String? _selectedPort;
  int _baudRate = 115200;
  bool _rtsEnabled = false;
  bool _dtrEnabled = false;
  bool _addCRLF = false;
  bool _hexDisplayMode = false;
  bool _parseIMU = false;

  final ImuDataParser _imuParser = ImuDataParser();

  StreamSubscription? _lineSubscription;
  StreamSubscription? _rawSubscription;

  final List<String> _receivedData = [];
  String _incompleteLine = "";

  final TextEditingController _sendController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

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

  @override
  bool get wantKeepAlive => true;

  bool get _isSavingToFile => widget.serialService.isSavingToFile;

  @override
  void initState() {
    super.initState();
    _refreshPorts();
    _subscribeToStream();
  }

  void _processIncomingData(String incomingText) {
    if (!mounted) return;
    setState(() {
      _incompleteLine += incomingText;

      // Split into lines
      int maxLineLength = (_hexDisplayMode && !_parseIMU)
          ? 90
          : 10240; // 在 HEX 模式且不解析IMU时，每 30 个字节(约90字符)强制折行以防无换行符卡死
      int index;
      while (true) {
        index = _incompleteLine.indexOf('\n');
        if (index != -1 && index <= maxLineLength) {
          String line = _incompleteLine.substring(0, index);
          if (line.endsWith('\r')) {
            line = line.substring(0, line.length - 1);
          }
          _receivedData.add(line);
          _incompleteLine = _incompleteLine.substring(index + 1);
        } else if (_incompleteLine.length > maxLineLength) {
          // 强制折行
          String line = _incompleteLine.substring(0, maxLineLength);
          _receivedData.add(line);
          _incompleteLine = _incompleteLine.substring(maxLineLength);
        } else {
          break;
        }
      }

      // Limit buffer size to save memory on Raspberry Pi
      if (_receivedData.length > 1000) {
        _receivedData.removeRange(0, _receivedData.length - 1000);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void didUpdateWidget(SerialDebugContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serialService != oldWidget.serialService) {
      _lineSubscription?.cancel();
      _rawSubscription?.cancel();
      _subscribeToStream();
    }
  }

  void _subscribeToStream() {
    // 2. 监听原始数据并按模式统一解码显示
    _rawSubscription = widget.serialService.dataStream.listen(
      (data) {
        if (mounted) {
          if (_hexDisplayMode && _parseIMU) {
            _imuParser.parseData(data, (imuData) {
              if (mounted) {
                _processIncomingData('$imuData\n');
              }
            });
          } else {
            String text;
            if (_hexDisplayMode) {
              // 二进制按 HEX 格式显示，使用 StringBuffer 提高大量数据时的拼接性能
              StringBuffer buffer = StringBuffer();
              for (int i = 0; i < data.length; i++) {
                buffer.write(
                  data[i].toRadixString(16).padLeft(2, '0').toUpperCase(),
                );
                buffer.write(' ');
              }
              text = buffer.toString();
            } else {
              // 统一按照字符处理，保持原汁原味的字符表现，非法 UTF-8 序列保留为乱码占位符
              text = utf8.decode(data, allowMalformed: true);
            }
            _processIncomingData(text);
          }
        }
      },
      onError: (error) {
        if (mounted) {
          _showError("数据接收异常: $error");
          setState(() {});
        }
      },
    );
  }

  Future<void> _toggleSaveToFile() async {
    if (_isSavingToFile) {
      await _stopSavingToFile();
    } else {
      if (_selectedPort == null) {
        _showError("请先选择串口");
        return;
      }

      if (!widget.serialService.isOpen) {
        _showError("请先打开串口");
        return;
      }

      await _startSavingToFile(_selectedPort!);
    }
  }

  Future<void> _startSavingToFile(
    String portName, {
    bool showMessage = true,
  }) async {
    try {
      final filePath = await _buildSerialSaveFilePath(portName);
      await widget.serialService.startSavingToFile(filePath);

      if (!mounted) return;
      setState(() {});

      if (showMessage) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("开始保存到文件: $filePath")));
      }
    } catch (e) {
      if (mounted) {
        _showError("无法创建文件: $e");
      }
    }
  }

  Future<void> _stopSavingToFile({bool showMessage = true}) async {
    try {
      await widget.serialService.stopSavingToFile();

      if (!mounted) return;
      setState(() {});

      if (showMessage) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text("已停止保存文件")));
      }
    } catch (e) {
      if (mounted) {
        _showError("关闭保存文件失败: $e");
      }
    }
  }

  Future<void> _refreshPorts() async {
    // 使用 compute 将耗时的串口扫描操作放到后台 isolate 执行，避免阻塞 UI 线程
    List<String> ports = [];
    try {
      ports = await compute(_getKnownPorts, null);
    } catch (e) {
      if (!mounted) return;
      _processIncomingData("[错误] 无法获取串口列表: $e\n");
    }

    if (!mounted) return;

    setState(() {
      _availablePorts = ports;
      if (_availablePorts.isNotEmpty && _selectedPort == null) {
        _selectedPort = _availablePorts.first;
      } else if (!_availablePorts.contains(_selectedPort)) {
        _selectedPort = _availablePorts.isNotEmpty
            ? _availablePorts.first
            : null;
      }
    });
  }

  Future<void> _togglePort() async {
    if (_selectedPort == null) return;

    if (widget.serialService.isOpen) {
      await _closePort();
    } else {
      await _openPort();
    }
  }

  Future<void> _openPort() async {
    try {
      widget.serialService.open(
        _selectedPort!,
        _baudRate,
        _rtsEnabled,
        _dtrEnabled,
      );

      if (widget.globalSaving) {
        await _startSavingToFile(_selectedPort!, showMessage: false);
      }

      if (!mounted) return;
      setState(() {}); // Update UI
    } catch (e) {
      _showError("打开串口异常: $e");
    }
  }

  Future<void> _closePort() async {
    if (_isSavingToFile) {
      await _stopSavingToFile(showMessage: false);
    }
    widget.serialService.close();
    if (mounted) {
      setState(() {}); // Update UI
    }
  }

  void _sendData() {
    if (!widget.serialService.isOpen) {
      _showError("串口未打开");
      return;
    }
    String textToSend = _sendController.text;
    if (textToSend.isEmpty) return;

    if (_addCRLF) {
      textToSend += "\r\n";
    }

    try {
      // Convert string to bytes (utf8)
      Uint8List bytes = Uint8List.fromList(utf8.encode(textToSend));
      widget.serialService.write(bytes);

      setState(() {
        if (_incompleteLine.isNotEmpty) {
          _receivedData.add(_incompleteLine);
          _incompleteLine = "";
        }
        _receivedData.add("[发送] $textToSend");
        // 已移除 _sendController.clear() 实现多次重发相同命令的需求
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    } catch (e) {
      _showError("发送失败: $e");
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _clearReceivedData() {
    setState(() {
      _receivedData.clear();
      _incompleteLine = "";
    });
  }

  @override
  void dispose() {
    _lineSubscription?.cancel();
    _rawSubscription?.cancel();
    _sendController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildLogArea() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
        color: Colors.black87,
      ),
      child: Stack(
        children: [
          if (_receivedData.isEmpty && _incompleteLine.isEmpty)
            const Center(
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  Icon(Icons.terminal, color: Colors.white70, size: 32),
                  Text('等待串口数据', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          SelectionArea(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _receivedData.length + 1,
              itemBuilder: (context, index) {
                String text;
                if (index < _receivedData.length) {
                  text = _receivedData[index];
                } else {
                  text = _incompleteLine;
                }
                return Text(
                  text,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontFamily: 'SourceCodePro',
                    fontFamilyFallback: ['SourceHanSansHWSC'],
                  ),
                );
              },
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: IconButton(
              icon: const Icon(Icons.cleaning_services, color: Colors.white70),
              onPressed: _clearReceivedData,
              tooltip: '清空接收区',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsArea() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionCard(
          title: '串口连接',
          icon: Icons.usb,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _selectedPort,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '串口'),
                      items: _availablePorts
                          .map(
                            (port) => DropdownMenuItem(
                              value: port,
                              child: Text(
                                port,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: widget.serialService.isOpen
                          ? null
                          : (v) => setState(() => _selectedPort = v),
                    ),
                  ),
                  IconButton(
                    onPressed: _refreshPorts,
                    icon: const Icon(Icons.refresh),
                    tooltip: '刷新串口列表',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _baudRate,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '波特率'),
                items: _baudRates
                    .map(
                      (rate) =>
                          DropdownMenuItem(value: rate, child: Text('$rate')),
                    )
                    .toList(),
                onChanged: widget.serialService.isOpen
                    ? null
                    : (v) {
                        if (v != null) setState(() => _baudRate = v);
                      },
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilterChip(
                    label: const Text('RTS'),
                    selected: _rtsEnabled,
                    onSelected: widget.serialService.isOpen
                        ? null
                        : (v) => setState(() => _rtsEnabled = v),
                  ),
                  FilterChip(
                    label: const Text('DTR'),
                    selected: _dtrEnabled,
                    onSelected: widget.serialService.isOpen
                        ? null
                        : (v) => setState(() => _dtrEnabled = v),
                  ),
                  FilterChip(
                    label: const Text('HEX'),
                    selected: _hexDisplayMode,
                    onSelected: (v) => setState(() {
                      _hexDisplayMode = v;
                      if (!v) _parseIMU = false;
                    }),
                  ),
                  if (_hexDisplayMode)
                    FilterChip(
                      label: const Text('解析IMU'),
                      selected: _parseIMU,
                      onSelected: (v) => setState(() => _parseIMU = v),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _selectedPort == null ? null : _togglePort,
                icon: Icon(
                  widget.serialService.isOpen ? Icons.link_off : Icons.link,
                ),
                label: Text(widget.serialService.isOpen ? '关闭串口' : '打开串口'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppSectionCard(
          title: '发送与保存',
          icon: Icons.send_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _sendController,
                decoration: const InputDecoration(
                  labelText: '发送内容',
                  hintText: '输入要发送的内容…',
                ),
                onSubmitted: (_) => _sendData(),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                    label: const Text(r'自动添加 \r\n'),
                    selected: _addCRLF,
                    onSelected: (v) => setState(() => _addCRLF = v),
                  ),
                  FilledButton.icon(
                    onPressed: _sendData,
                    icon: const Icon(Icons.send_outlined),
                    label: const Text('发送'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: widget.globalSaving ? null : _toggleSaveToFile,
                icon: Icon(_isSavingToFile ? Icons.stop : Icons.save_alt),
                label: Text(
                  widget.globalSaving
                      ? '一键保存中'
                      : (_isSavingToFile ? '停止保存' : '保存到文件'),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= 880 &&
              MediaQuery.textScalerOf(context).scale(14) <= 21;
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildLogArea()),
                const SizedBox(width: 16),
                SizedBox(width: 360, child: _buildControlsArea()),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: _buildLogArea()),
              const SizedBox(height: 12),
              Expanded(child: _buildControlsArea()),
            ],
          );
        },
      ),
    );
  }
}

List<String> _getKnownPorts(dynamic message) {
  return SerialPort.availablePorts;
}

Future<String> _buildSerialSaveFilePath(String portName) async {
  final directory = await getApplicationDocumentsDirectory();
  final now = DateTime.now();
  final formatter = DateFormat('yyyy-MM-dd-HH-mm-ss');
  final timestamp = formatter.format(now);
  final safePortName = _safeSerialFileName(portName);
  return '${directory.path}${Platform.pathSeparator}$safePortName-$timestamp.dat';
}

String _safeSerialFileName(String portName) {
  String name = portName;
  if (Platform.isLinux && name.startsWith('/dev/')) {
    name = name.substring(5);
  }
  return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}
