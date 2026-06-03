import 'dart:async';
import 'dart:typed_data';

/// 一帧完整的 IMU/GNSS 数据组合
class ImuData {
  int? tid;

  // 0x01: IMU温度
  double? tempImu;

  // 0x10: 加速度 (m/s^2)
  double? ax;
  double? ay;
  double? az;

  // 0x20: 角速度 (rad/s)
  double? wx;
  double? wy;
  double? wz;

  // 0x40: 欧拉角 (deg)
  double? pitch;
  double? roll;
  double? yaw;

  // 0x41: 四元数
  double? q0;
  double? q1;
  double? q2;
  double? q3;

  // 0x50: UTC时间
  int? utcMsec;
  int? utcUsec;
  int? utcYear;
  int? utcMonth;
  int? utcDay;
  int? utcHour;
  int? utcMin;
  int? utcSec;

  int? get utcSubsecondUsec {
    if (utcUsec != null) return utcUsec;
    if (utcMsec != null) return utcMsec! * 1000;
    return null;
  }

  int get utcDateTimeMsec => (utcSubsecondUsec ?? 0) ~/ 1000;
  int get utcDateTimeUsec => (utcSubsecondUsec ?? 0) % 1000;

  bool get isUtcWholeSecond {
    final usec = utcSubsecondUsec;
    return usec != null && usec % 1000000 == 0;
  }

  // 0x68: 位置
  double? lat; // 度
  double? lon; // 度
  double? alt; // 米

  // 0x70: 速度 (m/s)
  double? ve;
  double? vn;
  double? vu;

  // 0x80: 状态
  int? fusionState;
  int? gnssState;

  String _f(double? val, int fractionDigits, int width) {
    if (val == null) return 'N/A'.padLeft(width);
    return val.toStringAsFixed(fractionDigits).padLeft(width);
  }

  String _d2(int? val) {
    if (val == null) return '00';
    return val.toString().padLeft(2, '0');
  }

  String _d3(int? val) {
    if (val == null) return '000';
    return val.toString().padLeft(3, '0');
  }

  bool _hasAll(List<Object?> values) {
    return values.every((value) => value != null);
  }

  String get utcFractionText {
    if (utcUsec != null) return utcUsec!.toString().padLeft(6, '0');
    return _d3(utcMsec);
  }

  @override
  String toString() {
    final parts = <String>[];

    if (_hasAll([utcYear, utcMonth, utcDay, utcHour, utcMin, utcSec])) {
      parts.add(
        'UTC: $utcYear-${_d2(utcMonth)}-${_d2(utcDay)} ${_d2(utcHour)}:${_d2(utcMin)}:${_d2(utcSec)}.$utcFractionText',
      );
    }
    if (tempImu != null) {
      parts.add('Temp: ${_f(tempImu, 2, 7)} C');
    }
    if (_hasAll([wx, wy, wz])) {
      parts.add(
        'Gyro: [ ${_f(wx, 6, 10)}, ${_f(wy, 6, 10)}, ${_f(wz, 6, 10)} ]',
      );
    }
    if (_hasAll([ax, ay, az])) {
      parts.add(
        'Acc: [ ${_f(ax, 6, 9)}, ${_f(ay, 6, 9)}, ${_f(az, 6, 9)} ]',
      );
    }
    if (_hasAll([lat, lon, alt])) {
      parts.add(
        'Pos: [ Lat:${_f(lat, 10, 14)}, Lon:${_f(lon, 10, 14)}, Alt:${_f(alt, 3, 8)} ]',
      );
    }
    if (_hasAll([ve, vn, vu])) {
      parts.add(
        'Vel: [ E:${_f(ve, 3, 7)}, N:${_f(vn, 3, 7)}, U:${_f(vu, 3, 7)} ]',
      );
    }
    if (_hasAll([pitch, roll, yaw])) {
      parts.add(
        'Euler: [ P:${_f(pitch, 6, 11)}, R:${_f(roll, 6, 11)}, Y:${_f(yaw, 6, 11)} ]',
      );
    }
    if (_hasAll([fusionState, gnssState])) {
      parts.add('Status: [FS:$fusionState, GNSS:$gnssState]');
    }

    return '{${parts.join(', ')}}';
  }
}

/// 解析私有二进制协议
class ImuDataParser {
  static final _imuDataStreamController = StreamController<ImuData>.broadcast();
  static Stream<ImuData> get imuDataStream => _imuDataStreamController.stream;

  final List<int> _buffer = [];

  /// 推入字节数据并尝试解析出完整帧。成功时调用 [onParsed] 回调。
  void parseData(
    List<int> data,
    void Function(ImuData) onParsed, {
    bool broadcast = true,
  }) {
    _buffer.addAll(data);

    // 最小帧长度: 帧头(2) + TID(2) + LEN(1) + CK1,CK2(2) = 7 bytes
    while (_buffer.length >= 7) {
      int i = 0;
      bool found = false;
      // 遍历寻找帧头 0x59 0x53
      for (; i < _buffer.length - 1; i++) {
        if (_buffer[i] == 0x59 && _buffer[i + 1] == 0x53) {
          found = true;
          break;
        }
      }

      if (!found) {
        // 如果没找到，但最后一个字节是 0x59，保留最后一个字节，下次拼装测试
        if (_buffer.isNotEmpty && _buffer.last == 0x59) {
          _buffer.removeRange(0, _buffer.length - 1);
        } else {
          _buffer.clear();
        }
        break;
      }

      // 发现帧头在索引 i 处。接下来确保有足够的字节读取 LEN。
      if (_buffer.length < i + 5) {
        // 数据不够读取长度位，将 i 之前无用数据丢掉，留待下一次
        if (i > 0) _buffer.removeRange(0, i);
        break;
      }

      int payloadLen = _buffer[i + 4];
      int frameTotalLen = 5 + payloadLen + 2;

      // 检查当前缓冲区是否囊括了该计算总长的整帧
      if (_buffer.length < i + frameTotalLen) {
        // 数据不够一整帧
        if (i > 0) _buffer.removeRange(0, i);
        break;
      }

      // 校验 CK1, CK2
      int ck1 = 0;
      int ck2 = 0;
      // 校验范围：从 TID(i+2) 开始，到 Message 的最后一个字节(i+4+payloadLen)
      for (int k = i + 2; k < i + 5 + payloadLen; k++) {
        ck1 = (ck1 + _buffer[k]) & 0xFF;
        ck2 = (ck2 + ck1) & 0xFF;
      }

      if (ck1 == _buffer[i + 5 + payloadLen] &&
          ck2 == _buffer[i + 6 + payloadLen]) {
        // 校验通过，剥离负载体进行解析
        ImuData imuData = ImuData();
        ByteData bd = ByteData.view(
          Uint8List.fromList(_buffer.sublist(i, i + frameTotalLen)).buffer,
        );

        imuData.tid = bd.getUint16(2, Endian.little);

        int offset = 5; // payload 开始相对于帧头的位置
        int endOffset = 5 + payloadLen; // payload 结束的位置

        while (offset < endOffset) {
          int id = bd.getUint8(offset);
          int len = bd.getUint8(offset + 1);
          offset += 2;

          if (offset + len > endOffset) break; // 内部数据长度越界异常

          switch (id) {
            case 0x01: // IMU温度
              if (len == 2) {
                imuData.tempImu = bd.getInt16(offset, Endian.little) * 0.01;
              }
              break;
            case 0x10: // 加速度
              if (len == 12) {
                imuData.ax = bd.getInt32(offset, Endian.little) * 0.000001;
                imuData.ay = bd.getInt32(offset + 4, Endian.little) * 0.000001;
                imuData.az = bd.getInt32(offset + 8, Endian.little) * 0.000001;
              }
              break;
            case 0x20: // 角速度
              if (len == 12) {
                imuData.wx = bd.getInt32(offset, Endian.little) * 0.000001;
                imuData.wy = bd.getInt32(offset + 4, Endian.little) * 0.000001;
                imuData.wz = bd.getInt32(offset + 8, Endian.little) * 0.000001;
              }
              break;
            case 0x40: // 欧拉角
              if (len == 12) {
                imuData.pitch = bd.getInt32(offset, Endian.little) * 0.000001;
                imuData.roll =
                    bd.getInt32(offset + 4, Endian.little) * 0.000001;
                imuData.yaw = bd.getInt32(offset + 8, Endian.little) * 0.000001;
              }
              break;
            case 0x41: // 四元数
              if (len == 16) {
                imuData.q0 = bd.getInt32(offset, Endian.little) * 0.000001;
                imuData.q1 = bd.getInt32(offset + 4, Endian.little) * 0.000001;
                imuData.q2 = bd.getInt32(offset + 8, Endian.little) * 0.000001;
                imuData.q3 = bd.getInt32(offset + 12, Endian.little) * 0.000001;
              }
              break;
            case 0x50: // UTC
              if (len == 11) {
                imuData.utcMsec = bd.getUint32(offset, Endian.little);
                imuData.utcYear =
                    bd.getUint16(offset + 4, Endian.little) + 2000;
                imuData.utcMonth = bd.getUint8(offset + 6);
                imuData.utcDay = bd.getUint8(offset + 7);
                imuData.utcHour = bd.getUint8(offset + 8);
                imuData.utcMin = bd.getUint8(offset + 9);
                imuData.utcSec = bd.getUint8(offset + 10);
              }
              break;
            case 0x51: // UTC微秒扩展
              if (len == 4) {
                final usec = bd.getUint32(offset, Endian.little);
                imuData.utcUsec = usec > 999999 ? 999999 : usec;
              }
              break;
            case 0x68: // 位置
              if (len == 20) {
                imuData.lat = bd.getInt64(offset, Endian.little) * 0.0000000001;
                imuData.lon =
                    bd.getInt64(offset + 8, Endian.little) * 0.0000000001;
                imuData.alt = bd.getInt32(offset + 16, Endian.little) * 0.001;
              }
              break;
            case 0x70: // 速度
              if (len == 12) {
                imuData.ve = bd.getInt32(offset, Endian.little) * 0.001;
                imuData.vn = bd.getInt32(offset + 4, Endian.little) * 0.001;
                imuData.vu = bd.getInt32(offset + 8, Endian.little) * 0.001;
              }
              break;
            case 0x80: // 状态
              if (len == 1) {
                int status = bd.getUint8(offset);
                imuData.fusionState = status & 0x0F;
                imuData.gnssState = (status >> 4) & 0x0F;
              }
              break;
          }
          offset += len;
        }

        onParsed(imuData); // 抛出有效帧结构
        if (broadcast) {
          _imuDataStreamController.add(imuData); // 发布到全局广播流
        }
        _buffer.removeRange(0, i + frameTotalLen); // 清理当前成功解析过的数据
      } else {
        // 校验失败！可能这一处 0x59 0x53 是伪造的数据段（比如正巧数据中有这两字节），安全起见剥离第一个 0x59 然后重新匹配后面的头
        _buffer.removeRange(0, i + 1);
      }
    }
  }
}
