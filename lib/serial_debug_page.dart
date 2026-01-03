import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'serial_service.dart';
import 'ntrip_service.dart';

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

  @override
  void initState() {
    super.initState();
    _ntripService.addListener(_onNtripStateChanged);

    // Add default tab (Main)
    _tabs.add(
      SerialTabItem(
        title: "主串口",
        service: SerialService(), // Singleton
        key: GlobalKey(),
        isClosable: false,
      ),
    );

    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  void _onNtripStateChanged() {
    if (mounted) setState(() {});
  }

  Color _getNtripStatusColor() {
    if (!_ntripService.hasConfig) {
      return Colors.grey;
    }
    return _ntripService.isConnected ? Colors.green : Colors.red;
  }

  void _addTab() {
    setState(() {
      _tabs.add(
        SerialTabItem(
          title: "串口 ${_tabs.length + 1}",
          service: SerialService.create(),
          key: GlobalKey(),
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
    _tabController.dispose();
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: initialIndex,
    );
  }

  @override
  void dispose() {
    _ntripService.removeListener(_onNtripStateChanged);
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 36,
        leading: widget.onOpenDrawer != null
            ? IconButton(
                icon: const Icon(Icons.menu),
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: widget.onOpenDrawer,
              )
            : null,
        title: const Text(
          '串口调试助手',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: _getNtripStatusColor(),
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
          IconButton(
            icon: const Icon(Icons.add),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: _addTab,
            tooltip: '新建串口连接',
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(30),
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            labelPadding: const EdgeInsets.symmetric(horizontal: 8),
            tabs: _tabs.asMap().entries.map((entry) {
              int idx = entry.key;
              SerialTabItem tab = entry.value;
              return Tab(
                height: 30,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tab.title, style: const TextStyle(fontSize: 13)),
                    if (tab.isClosable) ...[
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () => _removeTab(idx),
                        child: const Icon(Icons.close, size: 14),
                      ),
                    ],
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: _tabs.map((tab) {
          return SerialDebugContent(key: tab.key, serialService: tab.service);
        }).toList(),
      ),
    );
  }
}

class SerialTabItem {
  String title;
  final SerialService service;
  final GlobalKey key;
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

  const SerialDebugContent({super.key, required this.serialService});

  @override
  State<SerialDebugContent> createState() => _SerialDebugContentState();
}

class _SerialDebugContentState extends State<SerialDebugContent>
    with AutomaticKeepAliveClientMixin {
  List<String> _availablePorts = [];
  String? _selectedPort;
  int _baudRate = 115200;
  bool _rtsEnabled = false;
  bool _dtrEnabled = false;
  bool _addCRLF = false;
  bool _isSavingToFile = false;
  IOSink? _fileSink;
  String? _currentSaveFilePath;

  StreamSubscription? _dataSubscription;

  final List<String> _receivedData = [];
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

  @override
  void initState() {
    super.initState();
    _refreshPorts();
    _subscribeToStream();
  }

  @override
  void didUpdateWidget(SerialDebugContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serialService != oldWidget.serialService) {
      _dataSubscription?.cancel();
      _subscribeToStream();
    }
  }

  void _subscribeToStream() {
    _dataSubscription = widget.serialService.lineStream.listen(
      (line) {
        if (mounted) {
          if (_isSavingToFile && _fileSink != null) {
            _fileSink!.writeln(line);
          }
          setState(() {
            _receivedData.add(line);
            // Limit buffer size to save memory on Raspberry Pi
            if (_receivedData.length > 200) {
              _receivedData.removeAt(0);
            }
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_scrollController.hasClients) {
              _scrollController.jumpTo(
                _scrollController.position.maxScrollExtent,
              );
            }
          });
        }
      },
      onError: (error) {
        if (mounted) {
          _showError("串口异常断开: $error");
          setState(() {});
        }
      },
    );
  }

  Future<void> _toggleSaveToFile() async {
    if (_isSavingToFile) {
      // Stop saving
      await _fileSink?.flush();
      await _fileSink?.close();
      setState(() {
        _isSavingToFile = false;
        _fileSink = null;
        _currentSaveFilePath = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("已停止保存文件")),
        );
      }
    } else {
      // Start saving
      if (_selectedPort == null) {
        _showError("请先选择串口");
        return;
      }

      try {
        final directory = await getApplicationDocumentsDirectory();
        String portName = _selectedPort!;
        
        // Clean port name for filename
        if (Platform.isLinux && portName.startsWith('/dev/')) {
          portName = portName.substring(5);
        }
        
        final now = DateTime.now();
        final formatter = DateFormat('yyyy-MM-dd-HH-mm-ss');
        final timestamp = formatter.format(now);
        final fileName = '$portName-$timestamp.dat';
        final filePath = '${directory.path}/$fileName';
        
        final file = File(filePath);
        _fileSink = file.openWrite(mode: FileMode.append);
        
        setState(() {
          _isSavingToFile = true;
          _currentSaveFilePath = filePath;
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("开始保存到文件: $filePath")),
          );
        }
      } catch (e) {
        _showError("无法创建文件: $e");
      }
    }
  }

  void _refreshPorts() {
    setState(() {
      _availablePorts = SerialPort.availablePorts;
      if (_availablePorts.isNotEmpty && _selectedPort == null) {
        _selectedPort = _availablePorts.first;
      } else if (!_availablePorts.contains(_selectedPort)) {
        _selectedPort = _availablePorts.isNotEmpty
            ? _availablePorts.first
            : null;
      }
    });
  }

  void _togglePort() {
    if (_selectedPort == null) return;

    if (widget.serialService.isOpen) {
      _closePort();
    } else {
      _openPort();
    }
  }

  void _openPort() {
    try {
      widget.serialService.open(
        _selectedPort!,
        _baudRate,
        _rtsEnabled,
        _dtrEnabled,
      );
      setState(() {}); // Update UI
    } catch (e) {
      _showError("打开串口异常: $e");
    }
  }

  void _closePort() {
    if (_isSavingToFile) {
      _toggleSaveToFile(); // Stop saving if port is closed
    }
    widget.serialService.close();
    setState(() {}); // Update UI
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
        _receivedData.add("[发送] $textToSend\n");
        _sendController.clear();
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
    });
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _fileSink?.close();
    _sendController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildLogArea() {
    return Container(
      margin: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey),
        borderRadius: BorderRadius.circular(4.0),
        color: Colors.black87,
      ),
      child: Stack(
        children: [
          ListView.builder(
            controller: _scrollController,
            itemCount: _receivedData.length,
            itemBuilder: (context, index) {
              return Text(
                _receivedData[index],
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontFamily: 'SourceCodePro',
                  fontFamilyFallback: ['SourceHanSansHWSC'],
                ),
              );
            },
          ),
          Positioned(
            right: 8,
            top: 8,
            child: IconButton(
              icon: const Icon(
                Icons.cleaning_services,
                color: Colors.white70,
              ),
              onPressed: _clearReceivedData,
              tooltip: '清空接收区',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlsArea(bool isSmallScreen) {
    return Container(
      padding: const EdgeInsets.all(4.0),
      color: Colors.grey[200],
      child: SingleChildScrollView(
        child: Column(
          children: [
            // Panel 1: Serial Settings
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _selectedPort,
                            decoration: const InputDecoration(
                              labelText: '串口',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(),
                            ),
                            style: const TextStyle(fontSize: 14, color: Colors.black),
                            items: _availablePorts.map((port) {
                              return DropdownMenuItem(
                                value: port,
                                child: Text(port, style: const TextStyle(fontSize: 14, color: Colors.black)),
                              );
                            }).toList(),
                            onChanged: widget.serialService.isOpen
                                ? null
                                : (value) {
                                    setState(() {
                                      _selectedPort = value;
                                    });
                                  },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          iconSize: 20,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          onPressed: _refreshPorts,
                          tooltip: '刷新串口列表',
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _baudRate,
                            decoration: const InputDecoration(
                              labelText: '波特率',
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(),
                            ),
                            style: const TextStyle(fontSize: 14, color: Colors.black),
                            items: _baudRates.map((rate) {
                              return DropdownMenuItem(
                                value: rate,
                                child: Text(rate.toString(), style: const TextStyle(fontSize: 14, color: Colors.black)),
                              );
                            }).toList(),
                            onChanged: widget.serialService.isOpen
                                ? null
                                : (value) {
                                    if (value != null) {
                                      setState(() {
                                        _baudRate = value;
                                      });
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    isSmallScreen
                        ? Column(
                            children: [
                              Row(
                                children: [
                                  SizedBox(
                                    height: 24,
                                    child: Row(
                                      children: [
                                        Checkbox(
                                          value: _rtsEnabled,
                                          onChanged: widget.serialService.isOpen
                                              ? null
                                              : (value) {
                                                  setState(() {
                                                    _rtsEnabled = value ?? false;
                                                  });
                                                },
                                        ),
                                        const Text("RTS", style: TextStyle(fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    height: 24,
                                    child: Row(
                                      children: [
                                        Checkbox(
                                          value: _dtrEnabled,
                                          onChanged: widget.serialService.isOpen
                                              ? null
                                              : (value) {
                                                  setState(() {
                                                    _dtrEnabled = value ?? false;
                                                  });
                                                },
                                        ),
                                        const Text("DTR", style: TextStyle(fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              SizedBox(
                                width: double.infinity,
                                height: 32,
                                child: ElevatedButton.icon(
                                  onPressed: _selectedPort == null
                                      ? null
                                      : _togglePort,
                                  icon: Icon(
                                    widget.serialService.isOpen
                                        ? Icons.link_off
                                        : Icons.link,
                                    size: 16,
                                  ),
                                  label: Text(
                                    widget.serialService.isOpen
                                        ? '关闭串口'
                                        : '打开串口',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: widget.serialService.isOpen
                                        ? Colors.red
                                        : Colors.blue,
                                    foregroundColor: Colors.white,
                                    padding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Checkbox(
                                value: _rtsEnabled,
                                onChanged: widget.serialService.isOpen
                                    ? null
                                    : (value) {
                                        setState(() {
                                          _rtsEnabled = value ?? false;
                                        });
                                      },
                              ),
                              const Text("RTS"),
                              const SizedBox(width: 10),
                              Checkbox(
                                value: _dtrEnabled,
                                onChanged: widget.serialService.isOpen
                                    ? null
                                    : (value) {
                                        setState(() {
                                          _dtrEnabled = value ?? false;
                                        });
                                      },
                              ),
                              const Text("DTR"),
                              const Spacer(),
                              ElevatedButton.icon(
                                onPressed: _selectedPort == null
                                    ? null
                                    : _togglePort,
                                icon: Icon(
                                  widget.serialService.isOpen
                                      ? Icons.link_off
                                      : Icons.link,
                                ),
                                label: Text(
                                  widget.serialService.isOpen ? '关闭串口' : '打开串口',
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: widget.serialService.isOpen
                                      ? Colors.red
                                      : Colors.blue,
                                  foregroundColor: Colors.white,
                                ),
                              ),
                            ],
                          ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Panel 2: Send Area
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(4.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _sendController,
                            style: const TextStyle(fontSize: 14),
                            decoration: const InputDecoration(
                              hintText: '输入要发送的内容...',
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                            onSubmitted: (_) => _sendData(),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          onPressed: _sendData,
                          icon: const Icon(Icons.send),
                          color: Colors.blue,
                          iconSize: 24,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        SizedBox(
                          height: 24,
                          child: Row(
                            children: [
                              Checkbox(
                                value: _addCRLF,
                                onChanged: (value) {
                                  setState(() {
                                    _addCRLF = value ?? false;
                                  });
                                },
                              ),
                              const Text("自动添加 \\r\\n", style: TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                        const Spacer(),
                        SizedBox(
                          height: 28,
                          child: ElevatedButton.icon(
                            onPressed: _toggleSaveToFile,
                            icon: Icon(
                              _isSavingToFile ? Icons.stop : Icons.save_alt,
                              size: 14,
                            ),
                            label: Text(
                              _isSavingToFile ? "停止保存" : "保存到文件",
                              style: const TextStyle(fontSize: 12),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  _isSavingToFile ? Colors.red : Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return LayoutBuilder(
      builder: (context, constraints) {
        // Check if the screen is very narrow
        bool isNarrow = constraints.maxWidth < 400;

        return Column(
          children: [
            // Upper part: Received Data
            Expanded(flex: 2, child: _buildLogArea()),
            // Lower part: Dashboard / Configuration
            Expanded(
              flex: 1,
              child: _buildControlsArea(isNarrow),
            ),
          ],
        );
      },
    );
  }
}
