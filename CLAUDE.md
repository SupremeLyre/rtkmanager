# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RTK Manager is a Flutter desktop application for RTK (Real-Time Kinematic) GNSS configuration management and serial port debugging. It targets Chinese users and embedded Linux deployments (Raspberry Pi with flutter-pi). The UI is in Chinese.

## Build & Development Commands

```bash
flutter pub get                                    # Install dependencies
flutter run -d windows                             # Run on Windows (also: linux, macos)
flutter build windows --release                    # Build Windows release
flutter build linux --release                      # Build Linux release
flutter test                                       # Run tests (only default smoke test exists)
flutter analyze                                    # Run Dart analyzer
flutter pub run flutter_launcher_icons:main        # Regenerate app icons from icon/icon.png
```

### Raspberry Pi (flutter-pi) Deployment

```bash
flutter pub global activate flutterpi_tool
flutterpi_tool build --arch=arm64 --cpu=pi3 --release
# Copy build/flutter-pi/pi3-64 to the Pi, then run:
# flutter-pi /home/pi/rtkmanager_app/flutter-pi/pi3-64
```

**Note:** `flutterpi_tool` currently supports only Flutter 3.38, not 3.41 (as of 2026/4/13).

## Architecture

The app has 4 tabs managed by `HomePage` using an `IndexedStack` with a drawer navigation sidebar:

1. **Serial Debug** (`serial_debug_page.dart`) — Multi-tab serial port debugger with ASCII/HEX display and IMU binary protocol parsing.
2. **RTK Config** (`rtk_config_page.dart`) — NTRIP client configuration, mount point fetching, RTCM data logging and multi-port forwarding.
3. **Positioning** (`positioning_page.dart`) — Real-time map visualization using Amap (Gaode) tiles with WGS84-to-GCJ-02 coordinate conversion. Trajectory points are color-coded by positioning state (pink=SPP, blue=PPP, red=predicted).
4. **Satellite** (`satellite_page.dart`) — Satellite sky view from NMEA GSV sentences.

### Key Services (Singleton Pattern)

- `SerialService` (`serial_service.dart`) — Manages serial port I/O via `flutter_libserialport`. Delivers data through streams. Buffer safety limit is 4096 bytes.
- `NtripService` (`ntrip_service.dart`) — Handles NTRIP TCP connections, basic HTTP auth, source table parsing, and RTCM streaming.
- `ImuDataParser` (`imu_data_parser.dart`) — Parses a proprietary binary protocol (frame header `0x59 0x53`) for IMU/GNSS data.
- `SatelliteService` (within `satellite_info.dart`) — Parses NMEA GSV sentences.

### Window Management

`main.dart` uses `window_manager` with a hidden system title bar. A custom `CustomWindowFrame` renders macOS-style window buttons (close/minimize/maximize). Window defaults to 800x480 with a minimum of 400x300, designed for low-resolution and embedded displays. On Raspberry Pi (flutter-pi), `window_manager` throws `MissingPluginException`; the code catches and ignores this so the app runs fullscreen without a frame.

### Fonts

The app bundles `SourceCodePro` (monospace for serial data) and `SourceHanSansHWSC` (Chinese UI). The default font family is set to `SourceHanSansHWSC` in `main.dart`.

## Platform-Specific Requirements

- **Linux:** Install system packages `libserialport0` and `libserialport-dev`. The user must be in the `dialout` group for serial port access.
- **Raspberry Pi:** Same Linux requirements apply. `flutter-pi` does not support `window_manager`, so the custom title bar is silently disabled.

## Important Implementation Details

- The map uses Amap web tile URLs, not OpenStreetMap. Coordinate conversion from WGS84 to GCJ-02 is implemented inline in `positioning_page.dart`.
- Serial data display is optimized for high-frequency input: data is dynamically batched and parsed by an isolated decoder to reduce UI jitter.
- `RTK Config` can forward received RTCM data to multiple serial ports simultaneously and log raw RTCM streams to files.
- The project has minimal test coverage (only the default Flutter counter widget test in `test/widget_test.dart`).
