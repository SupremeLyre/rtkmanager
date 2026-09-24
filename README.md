# RTK Manager

RTK Manager 是一个基于 Flutter 的 GNSS / RTK 工具，提供串口调试、NTRIP 差分转发、定位轨迹展示、卫星信息监测和 IMU 批量解码。安卓端提供独立的蓝牙设备连接、GGA 日志管理及手机原始传感器数据采集流程。

## 平台与页面

| 页面 / 功能 | 桌面端（Windows / Linux / macOS） | 安卓端 |
| --- | --- | --- |
| 设备接入 | 多标签串口调试，支持 ASCII / HEX 收发 | BLE 扫描、连接与 GNSS 协议校验 |
| RTK 配置 | NTRIP 连接、挂载点获取、RTCM 转发与保存 | — |
| 定位结果 | 串口及文件中的 GGA、PPPSOL、IMU 导航结果 | 蓝牙 GGA 实时轨迹及 GGA 文件回放 |
| 卫星信息 | 可见卫星统计、信噪比图、天空图 | — |
| 日志存储 | 串口原始数据及 RTCM 文件保存 | GGA 按 UTC 日期自动归档、打开、分享与删除 |
| 手机数据采集 | — | GNSS 原始观测、加速度、角速度及磁场 |
| IMU 批量解码 | 文件导入、自选输出目录、CSV 导出 | 文件或手机采集导入、CSV 导出与分享 |
| IMU 数据可视化 | 选择已连接串口，实时解析并绘制三轴曲线 | 展示采集中的六轴 IMU 和独立磁场曲线 |

桌面端与安卓端共用蓝色主题、导航抽屉、页面标题、图标卡片、状态标签和空状态。IMU 批量解码共用同一套设置与文件队列；宽窗口并排显示设置和导出卡片，窄窗口自动纵向排列。桌面串口调试、RTK 配置和卫星信息也使用这些共享组件，保留各自的数据连接与操作功能。

## 桌面端功能

### 串口调试助手

- 主串口常驻，支持添加和关闭多个串口标签页。
- 支持 9600～921600 范围内的常用波特率、ASCII / HEX 显示及自定义指令发送。
- 可独立保存串口数据，也可一键开启或停止所有已连接串口的数据保存。
- 内置 IMU / GNSS 二进制协议解析，显示加速度、角速度、姿态、四元数、温度和导航状态等数据。
- 高频接收数据合并刷新，解析结果随窗口宽度自动换行。

### RTK 配置（NTRIP Client）

- 配置 Caster 地址、端口、用户名、密码及挂载点，支持获取挂载点列表。
- 接收 RTCM 差分数据，可同时转发至多个串口，并保存原始 RTCM 文件。
- 支持断线自动重连，运行日志展示连接、鉴权及数据接收状态。

### 定位结果与卫星信息

- 使用高德地图瓦片，支持缩放、平移、旋转和自动跟随最新定位点。
- 展示 GGA、`$PPPSOL` 及 IMU 导航轨迹，通过颜色与标记形状区分数据类型和定位状态。
- 内置 WGS84 → GCJ-02 转换；按数据类型显示 UTC、定位状态、卫星数、海拔、DOP、速度及精度等信息。
- 支持文件导入和时间轴逐历元查看。
- “图层管理”分别控制 GGA、PPPSOL、IMU 轨迹显隐；隐藏只影响地图显示，实时数据仍进入有界缓存。
- 解析 GSV 卫星信息，展示 GPS、GLONASS、Galileo、BeiDou、QZSS、NavIC 的可见卫星统计、信噪比及天空分布。

### MQTT 多设备定位（桌面 / 安卓）

1. 在“定位结果 → 数据来源 → MQTT 连接设置”填写服务器、端口和订阅主题，在“账号与安全”设置账号与 TLS。顶部查看设备、消息及落盘数量；“接收详情”展开缓存统计，“接收日志”直接打开保存文件列表。当前设备协议的默认服务器为 `121.37.254.162:1883`，主题为 `app`；账号只保留在本次运行内，不写入配置或日志。
2. 点击“连接并接收”，按 MQTT 3.1.1 订阅 UTF-8 JSON。解析 `device_id`、`send_time` 和 `gga`（兼容大写 `GGA`），校验 GGA 校验和、坐标及定位有效性；`rmc` 不参与本页面的位置展示。
3. 每个 `device_id` 自动成为独立图层，设备在缓存期间保持固定颜色，定位状态变化不会改变轨迹颜色。MQTT 模式隐藏桌面底部的定位状态图例。通过“图层管理”逐台显示、隐藏或定位设备；自动跟随当前选中的设备，避免在多台设备间跳动。
4. “查看定位详情”提供设备 ID、GGA 原文、定位 UTC、发送 UTC 和接收 UTC。断线自动重连并重新订阅；切换“串口 / 离线文件”（安卓为“蓝牙 / 离线文件”）只切换显示数据源，不删除另一来源的轨迹。

长时间接收采用**内存滚动缓存 + 本地追加日志**：每台设备最多 5,000 点、总计最多 20,000 点、最多 64 台最近活跃设备；达到上限先移出旧点或最久未更新的设备。隐藏图层同样受缓存上限约束。本地串口 / 蓝牙实时轨迹最多保留 5,000 点，查看较早历元时也不再无限增长。

有效且非重复、非过期的 MQTT 定位记录按接收日（UTC）追加到 `MQTTyyyyMMdd.jsonl`，每行包含 `device_id`、`gga`、`send_time`、`received_at`。日志独立于地图缓存，清除地图不会删除文件，重启后同日继续追加。桌面目录为系统“文档”下的 `RTKManager/MQTT`；安卓目录为应用外部文件目录的 `Documents/MQTT`（不可用时使用应用内部 `MQTT`）。在“数据来源 → MQTT 接收日志”查看最近 60 个文件，安卓可分享、桌面可复制路径。日志不会自动删除，可按需备份清理。

磁盘写入按批次串行进行，待写队列最多 2,000 条；存储异常时重试并在界面显示错误。队列满后新增待写记录会计入“未能保存”，避免存储故障造成内存无限积压。MQTT QoS 0 本身不保证断线期间的消息送达，本地日志仅保存实际收到并通过检查的数据。

## 安卓端功能

安卓端通过侧边抽屉切换六个页面：**设备连接、定位结果、日志存储、手机数据采集、IMU 批量解码、IMU 数据可视化**。

### 设备连接与定位

1. 在“设备连接”点击“扫描设备”，按系统提示授予蓝牙相关权限。
2. 列表默认隐藏未命名设备，可开启“显示未命名设备”查看全部结果。支持按设备名称或蓝牙地址搜索（不区分大小写，地址可省略冒号）；搜索涵盖全部扫描结果。选择设备后校验 GNSS 服务、特征及通知能力，不按名称关键词或广播 UUID 排除接收机。
3. 连接成功后查看 GGA 接收计数和最近一条消息，点击“查看定位结果”进入地图。
4. 在地图中使用自动跟随、恢复北向、清除轨迹及定位详情；断开连接后可导入包含 GGA、PPPSOL、IMU 定位结果的文件进行回放。移动端提供三类轨迹的图层开关和定位详情，隐藏底部图例；IMU 需要数据帧内含有效时间与位置，纯六轴采样不生成定位轨迹。

切换页面会保留已建立的蓝牙连接并继续接收数据。实时连接期间不可导入历史文件；文件导入期间不可建立新连接。新连接成功时清空旧轨迹并恢复跟随。

蓝牙接入使用项目约定的 GNSS GATT 协议，协议 UUID、MTU、通知格式及权限说明见 [Android 蓝牙定位](docs/android-bluetooth.md)。

### GGA 日志存储

- 通过校验的蓝牙 GGA 自动保存为 `GGAyyyyMMdd.txt`，日期取手机接收时刻的 **UTC 日期**。
- 同一天持续追加，跨 UTC 零点切换文件；重启或重新连接不会覆盖已有日志。
- “日志存储”显示文件修改时间（UTC），支持打开、分享和删除。
- 导入地图的历史文件不会重复写入日志；删除当天日志后，新消息会重新生成当天文件。

### 手机原始数据采集

1. 开启系统定位，建议在室外点击“检测传感器”，授予精确位置权限。
2. 勾选 GNSS、IMU 或磁传感器；IMU 同时检测加速度计和陀螺仪，两者都有有效数据才可勾选。
3. 等待 **GNSS 时间同步**，分别设置 IMU（25 / 50 / 100 / 200 Hz）与磁力计（10 / 25 / 50 / 100 / 200 Hz）的请求频率，然后开始采集。页面显示硬件上限和实测输出频率，超过硬件能力的请求按上限注册。
4. 采集通过安卓前台服务运行，可在页面或通知中停止；停止后分享采集文件。
5. 在“IMU 批量解码”选择“导入手机采集”，将 BIN 转换为 CSV。

手机采集要求 Android 10 及以上，并且硬件能够提供 GNSS 与传感器时间的对应关系。未检测到有效数据的传感器不可勾选；仅采集 IMU / 磁场也需要 GNSS 授时，完成时间同步后才能开始采集。

每次采集建立独立会话目录，根据所选内容生成文件：

| 文件 | 内容 |
| --- | --- |
| `observations.rtcm3` | 手机 GNSS 的 RTCM3 MSM7 观测量 |
| `gnss_raw.csv` | GNSS 原始测量、状态及推导观测量 |
| `imu.bin` | 一条记录同时包含三轴加速度和三轴角速度，时间取陀螺仪采样时刻 |
| `imu_pairs.csv` | 六轴记录的 TID、GPS 时间、两个传感器原始时间戳及配对时间差 |
| `mag.bin` | 三轴磁场采样帧 |
| `sensors_raw.csv` | 原始传感器数值、时间戳、精度状态及硬件偏置 |
| `clock.csv` | GNSS 时间与传感器时钟的映射及不确定度 |
| `session.json` | 手机、传感器、单位、采样配置、计数及结束原因 |

RTCM3 文件只包含观测量，不包含广播星历；后处理定位需要另行准备匹配的星历。文件格式、时间基准、坐标轴及硬件限制见 [手机原始数据采集](docs/phone-capture.md)。

北斗 B2a 临时兼容：在 1176.45 MHz 频段（误差小于 20 kHz）将手机上报的 `Q` 按导频 `P` 编码，MSM 信号号为 23，对应 RINEX `5P`。原始 CSV 仍保留 `Q`，ADR 有效性检查保持不变；其他频段不应用此规则。补丁基于 Q 表示 B2a 导频的兼容假设，只影响更新后的采集输出。

IMU 按采样时间在半个有效请求周期内一对一配对，不插值、不重复使用样本；未配对样本保留在原始 CSV 并计数。磁力计独立输出，较低的磁场频率不会降低 IMU 的请求频率。

例如本次实测的 OPPO PLG110（Android 16），当前使用的磁力计报告最短周期为 20 ms，即最高 50 Hz；请求 100 Hz 时实际约 49.93 Hz。IMU 独立请求 100 Hz，实际约 99.82 Hz。请求频率是向系统提出的采样要求，最终输出以硬件能力和实测时间戳为准。

## IMU 实时可视化

两个平台复用同一套曲线页面，显示加速度（g）、角速度（°/s）、磁场（µT）的 X / Y / Z 三轴数值和实测频率。

- **桌面端**：先连接串口，再进入“IMU 数据可视化”选择已连接端口；从二进制数据自动解析，无需开启串口文本页的 HEX / IMU 显示开关。
- **手机端**：在“手机数据采集”开始采集后，点击“IMU 实时曲线”或从抽屉进入；实时展示的数据帧与写入 BIN 的数据一致。
- 支持最近 5 / 10 / 30 秒窗口、自动纵轴、暂停 / 继续显示和清除曲线。暂停与清除不会停止采集或删除文件。
- 断流时保留最后画面并提示停止；缺失传感器数据不补零。频率优先由帧内采样时间计算，无时间字段时使用接收时间并标注。

## IMU 批量解码

- 支持导入多个二进制文件，逐文件展示解码进度和完成状态。
- 可选择只解码组合导航结果，或导出原始 IMU 数据；可附加磁场、欧拉角、四元数、位置、速度、状态、温度和 TID 字段。
- CSV 使用 `GPSWeek`、`GPSSow` 表示时间；手机采集数据优先使用 GPST 扩展字段，无需 TID 时间补偿。
- 加速度单位为 **g**，角速度为 **°/s**，磁场为 **µT**。未采集的字段留空，实测零值正常保留。
- 桌面端可选择输出目录，默认与源文件同目录；安卓端输出至手机采集目录下的 `Decoded`，可直接分享 CSV。

## 界面与交互

- **统一风格**：蓝色主色、浅色背景，使用思源等宽中文字体及 Source Code Pro。
- **桌面端**：通过 `window_manager` 管理自定义窗口及红黄绿窗口按钮；IMU 解码设置使用卡片布局，页标题与串口调试、RTK 配置保持一致。
- **安卓端**：使用状态卡片、蓝牙示意图、传感器图标、数据摘要和文件卡片组织信息；解码页按导入、设置、导出三个步骤排列。
- **地图信息**：安卓地图采用分层工具栏、定位摘要和详情弹层，小屏或大字体下收起次要指标。
- **屏幕适配**：支持小窗口、手机横屏和系统大字体；安卓通过安全区处理避开状态栏、刘海与底部导航区域。

## 开发环境

| 项目 | 配置 |
| --- | --- |
| Flutter | 本次验证使用 3.41.6 |
| Dart | `pubspec.yaml` 要求 `^3.8.1`，即 `>=3.8.1 <4.0.0`；本次验证使用 3.11.4 |
| Android 构建 | Gradle 8.12、Android Gradle Plugin 8.7.3、Kotlin 2.1.0；已使用 JDK 21 构建验证 |
| Windows 构建 | Visual Studio 及“使用 C++ 的桌面开发”工作负载 |
| Linux 串口运行 | `libserialport0` 及串口设备访问权限 |

Android 的 SDK / NDK 版本配置见 [android/app/build.gradle.kts](android/app/build.gradle.kts)，Flutter 依赖与版本约束见 [pubspec.yaml](pubspec.yaml)。

## 获取与运行

### 获取代码与依赖

```bash
git clone https://github.com/SupremeLyre/rtkmanager.git
cd rtkmanager
flutter pub get
flutter doctor -v
```

### 桌面端

在相应操作系统上运行：

```bash
flutter run -d windows
# Linux：flutter run -d linux
# macOS：flutter run -d macos
```

Windows 发布构建：

```bash
flutter build windows --release
```

运行文件位于 `build/windows/x64/runner/Release/`，分发时保留该目录内的 DLL 和 `data` 等配套文件。

Windows 端在 RDP 与本地桌面切换、解锁或显示缩放变化后，会重新同步界面 DPI 和内容尺寸，并在随后两秒内补查显示设置。无需重启应用，采集及连接状态保留；缩放跟随当前显示器，不固定为 100% 或 200%。

### 安卓端

连接已开启 USB 调试的手机，使用 `flutter devices` 列出的设备 ID：

```bash
flutter devices
flutter run -d <设备ID>
flutter build apk --release
```

APK 输出位置为 `build/app/outputs/flutter-apk/app-release.apk`。调试包可使用 `flutter build apk --debug` 构建。

若 Flutter 使用了与本项目 Gradle 不兼容的 Java 版本，可将 JDK 路径指定为本机安装的 JDK 21 后再构建：

```bash
flutter config --jdk-dir="<本机JDK21路径>"
flutter doctor -v
```

该设置影响本机 Flutter 的后续构建。当前项目的 release 构建仍使用 debug 签名，正式发布前应在 `android/app/build.gradle.kts` 中配置自己的签名。

### Linux 与树莓派

Debian / Ubuntu / Raspberry Pi OS 可安装串口运行库，并将当前用户加入串口访问组：

```bash
sudo apt-get update
sudo apt-get install libserialport0
sudo usermod -a -G dialout "$USER"
```

组权限变更后重新登录或重启。缺少串口运行库时可能出现 `failed to load dynamic library libserialport.so`。

树莓派可使用 `flutter-pi` 运行。构建前需匹配 `flutterpi_tool`、目标引擎和 Flutter SDK 版本；该流程应单独核对，不直接沿用上表的桌面 / 安卓验证版本。以 64 位 Raspberry Pi 3B+ 为例：

```bash
dart pub global activate flutterpi_tool
flutterpi_tool build --arch=arm64 --cpu=pi3 --release
```

将生成的 `build/flutter-pi/pi3-64` 目录复制到树莓派后，在目标设备执行：

```bash
flutter-pi /home/pi/rtkmanager_app/flutter-pi/pi3-64
```

## 数据保存与使用说明

- 地图瓦片需要网络连接。
- 安卓蓝牙连接与手机传感器采集是独立功能；进入采集页不会自动启动传感器，需先点击“检测传感器”。
- 安卓 GGA 日志通常位于应用的 `Documents/GGA`，手机采集位于 `Documents/PhoneCapture`；实际完整路径以页面显示为准。
- 上述安卓目录属于应用数据，卸载或清除应用数据时会删除，需要保留的文件请先分享导出。
- 不可用的传感器、缺失载波相位或中断的时钟同步会按实际状态处理，详细规则见手机采集文档。

## 验证

在项目根目录执行：

```bash
flutter analyze lib test integration_test test_driver
flutter test
```

测试覆盖 GGA 解析与日志、蓝牙连接状态、六轴 IMU 解码与 CSV 输出、手机采集的传感器和授时条件、独立采样率、实时曲线数据流、串口切换，以及安全区、小屏、横屏、大字体和减少动画设置下的页面布局。

原生采集格式校验及跨语言样本位于 `test/native/` 和 `test/fixtures/`，说明见 [手机原始数据采集](docs/phone-capture.md)。

Windows DPI 同步回归可在已配置 Visual Studio C++ 工具链的终端执行：

```bash
cmake -S windows/runner/tests -B build/windows-dpi-tests -A x64
cmake --build build/windows-dpi-tests --config Release
ctest --test-dir build/windows-dpi-tests -C Release --output-on-failure
```

该测试使用隐藏窗口验证会话通知、DPI 与内容尺寸的更新顺序、延迟补查和退出清理，不改变系统缩放。真实 RDP 验收：保持应用运行，从 1920×1080 / 100% 的远程桌面切回 3200×2000 / 200% 的本地桌面，检查文字、图标、点击位置以及当前连接；普通窗口、最大化窗口和最小化后恢复均需检查，再反向切回远程桌面复测。

### 安卓实机采集回归

连接并解锁支持 100 Hz IMU、磁力计和 GNSS 授时的安卓手机，开启精确定位，放在室外或窗边，并先停止已有采集：

```bash
flutter drive -d <设备ID> --keep-app-running --driver=test_driver/integration_test.dart --target=integration_test/phone_capture_test.dart
```

测试通过界面检测传感器，分别请求 100 Hz IMU 与磁场，检查实时曲线和暂停显示后持续采集，再读取新建会话中的 BIN 与配对 CSV，核对六轴完整性、记录数量、时间顺序、配对误差及磁力计上限。测试保留采集文件，将测量报告写入 `build/integration_response_data.json`；没有真实 GNSS 时间时会失败，不使用模拟时钟或传感器数据。

保留 `--keep-app-running` 参数：Flutter Drive 默认结束清理会卸载应用，连同应用数据一起删除。该参数保留安装及文件；测试本身会停止由它发起的采集。

2026-09-19 在 OPPO PLG110 上通过：1,384 条 IMU、692 条磁场记录；文件计算频率分别为 99.82 Hz 和 49.93 Hz，最大配对时间差为 0 ns，未配对样本为 0。该结果代表本次采集，其他设备应以各自报告和实际输出为准。

测试入口与正常应用入口分开。测试结束后运行 `flutter run -d <设备ID> -t lib/main.dart` 装回正常版本。需要手动检查界面时，可使用 `flutter run -d <设备ID> -t test_driver/interactive.dart` 启用开发专用界面驱动；正常 `lib/main.dart` 不启用该驱动。

## 主要依赖

| 依赖 | 用途 |
| --- | --- |
| `flutter_libserialport` | 桌面串口通信 |
| `flutter_map` / `latlong2` | 地图渲染与地理坐标 |
| `window_manager` / `screen_retriever` | 桌面窗口管理与屏幕工作区适配 |
| `file_picker` / `path_provider` | 文件选择及本地路径 |
| `intl` | 日期与时间格式化 |

安卓 BLE、GNSS 原始观测及传感器采集通过 Kotlin 原生接口和 Flutter 平台通道实现。

## 作者与版本

- 作者：SupremeLyre
- 当前版本：`1.0.0+1`（以 `pubspec.yaml` 为准）
