# RTK Manager

RTK Manager 是一个基于 Flutter 开发的跨平台应用程序，主要用于 RTK (Real-Time Kinematic) 配置管理和串口调试。

## 功能特性

### 1. 串口调试助手
*   **多标签页支持**：支持同时打开多个串口进行调试，主串口常驻，可动态添加/关闭新的串口标签页。
*   **串口配置**：支持常见的波特率设置 (9600 - 921600)。
*   **数据收发**：实时显示串口接收数据，支持发送指令。

### 2. RTK 配置 (NTRIP Client)
*   **NTRIP 客户端**：内置 NTRIP 协议支持，可连接 CORS 账号获取差分数据。
*   **参数配置**：
    *   支持配置 NTRIP Caster 的 IP、端口、用户名和密码。
    *   支持获取并选择挂载点 (Mount Point)。
*   **自动重连**：支持断线自动重连功能，保证数据链路稳定性。
*   **数据转发**：
    *   **串口转发**：支持将接收到的 RTK 差分数据转发到指定的串口（支持多路串口输出）。
    *   **文件存储**：支持将 RTK 数据实时保存到本地文件。
*   **日志记录**：实时显示连接状态和运行日志。

## 开发环境

*   **Flutter SDK**: ^3.8.1
*   **Dart SDK**: 对应 Flutter 版本

## 依赖库

本项目使用了以下主要开源库：

*   [flutter_libserialport](https://pub.dev/packages/flutter_libserialport): 用于串口通信。
*   [file_picker](https://pub.dev/packages/file_picker): 用于文件选择和保存。

## 安装与运行

1.  确保本地已安装 Flutter 开发环境。
2.  克隆本项目到本地。
3.  在项目根目录下运行以下命令获取依赖：
    ```bash
    flutter pub get
    ```
4.  运行项目（建议在 Windows 桌面环境下运行以获得完整的串口支持）：
    ```bash
    flutter run -d windows
    ```

## 作者

*   **SupremeLyre**

## 版本

*   1.0.0+1
