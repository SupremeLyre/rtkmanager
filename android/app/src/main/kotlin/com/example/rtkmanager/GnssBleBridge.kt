package com.example.rtkmanager

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** BLE central for the BlueNRG firmware in esp32/softAP. No GNSS writes are sent. */
@SuppressLint("MissingPermission") // Permissions are checked before scan/connection; revocation is handled below.
class GnssBleBridge(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        private val SERVICE = UUID.fromString("00000000-0001-11e1-9ab4-0002a5d5c51b")
        private val GNSS = UUID.fromString("00140000-0001-11e1-ac36-0002a5d5c51b")
        private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val PERMISSIONS = 701
        private const val ENABLE_BLUETOOTH = 702
        private const val REQUIRED_MTU = 259 // Firmware sends complete NMEA notifications, up to 256 bytes.
    }

    private val methods = MethodChannel(messenger, "rtkmanager/gnss_ble")
    private val events = EventChannel(messenger, "rtkmanager/gnss_ble/events")
    private val handler = Handler(Looper.getMainLooper())
    private val adapter get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private var sink: EventChannel.EventSink? = null
    private var pendingScan: MethodChannel.Result? = null
    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private val devices = mutableMapOf<String, BluetoothDevice>()
    private var gatt: BluetoothGatt? = null
    private var phase = "disconnected"
    private var mtu = 23
    private var disposed = false
    private val scanTimeout = Runnable { stopScan() }
    private val connectTimeout = Runnable { failConnection("连接超时，请确认设备已开机、在附近且未被其他手机占用") }

    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) == BluetoothAdapter.STATE_OFF) {
                val active = gatt != null || scanCallback != null
                stopScan()
                if (active) failConnection("蓝牙已关闭，请开启后重新连接")
            }
        }
    }

    init {
        methods.setMethodCallHandler(this)
        events.setStreamHandler(this)
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(adapterReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            activity.registerReceiver(adapterReceiver, filter)
        }
    }

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }

    override fun onCancel(arguments: Any?) {
        stopScan()
        cancelPendingScan()
        closeConnection()
        sink = null
    }

    private fun emit(type: String, vararg fields: Pair<String, Any?>) {
        if (!disposed) sink?.success(mapOf("type" to type, *fields))
    }

    private fun state(value: String, message: String? = null) {
        phase = value
        emit("state", "state" to value, "message" to message, "mtu" to mtu)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "startScan" -> {
                    if (pendingScan != null || gatt != null) {
                        result.error("busy", "请先断开当前连接或等待权限请求完成", null)
                        return
                    }
                    pendingScan = result
                    prepareScan()
                }
                "stopScan" -> { cancelPendingScan(); stopScan(); result.success(null) }
                "connect" -> {
                    val device = devices[call.argument<String>("id")]
                    if (device == null) {
                        result.error("not_found", "设备不在扫描列表中，请重新扫描", null)
                    } else if (requiredPermissions().any { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
                        result.error("permission", "蓝牙权限已关闭，请重新扫描并授权", null)
                    } else if (adapter?.isEnabled != true) {
                        result.error("disabled", "请开启蓝牙后重新扫描", null)
                    } else {
                        stopScan()
                        closeConnection()
                        state("connecting")
                        gatt = device.connectGatt(activity, false, callbacks, BluetoothDevice.TRANSPORT_LE)
                        if (gatt == null) throw IllegalStateException("无法创建蓝牙连接，请重试")
                        handler.postDelayed(connectTimeout, 20_000)
                        result.success(null)
                    }
                }
                "disconnect" -> { closeConnection(); state("disconnected"); result.success(null) }
                "openSettings" -> {
                    activity.startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        android.net.Uri.parse("package:${activity.packageName}")))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            if (call.method == "startScan") pendingScan = null
            if (call.method == "connect") failConnection("无法连接设备：${error.message}")
            result.error("bluetooth", error.message ?: "蓝牙操作失败，请重试", null)
        }
    }

    private fun requiredPermissions(): Array<String> = if (Build.VERSION.SDK_INT >= 31) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    private fun prepareScan() {
        if (pendingScan == null) return
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) || adapter == null) {
            finishScanRequest("此手机不支持 BLE 蓝牙")
            return
        }
        val missing = requiredPermissions().filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            activity.requestPermissions(missing.toTypedArray(), PERMISSIONS)
            return
        }
        continueScan()
    }

    private fun continueScan() {
        if (pendingScan == null) return
        try {
            if (adapter?.isEnabled != true) {
                @Suppress("DEPRECATION")
                activity.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), ENABLE_BLUETOOTH)
                return
            }
            if (Build.VERSION.SDK_INT < 31) {
                val location = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
                if (!location.isProviderEnabled(LocationManager.GPS_PROVIDER) && !location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                    finishScanRequest("此 Android 版本扫描蓝牙需要开启系统定位，请在手机设置中开启后重试")
                    return
                }
            }
            startScan()
            finishScanRequest()
        } catch (error: Exception) {
            stopScan()
            finishScanRequest(error.message ?: "扫描失败，请重试")
        }
    }

    fun onPermissionsResult(code: Int) {
        if (code != PERMISSIONS || pendingScan == null) return
        if (requiredPermissions().any { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
            finishScanRequest("需要蓝牙扫描和连接权限；若已拒绝，请在应用设置中允许权限后重试")
        } else continueScan()
    }

    fun onActivityResult(code: Int) {
        if (code != ENABLE_BLUETOOTH || pendingScan == null) return
        if (adapter?.isEnabled == true) continueScan() else finishScanRequest("蓝牙未开启，请开启后重试")
    }

    private fun finishScanRequest(error: String? = null) {
        val result = pendingScan ?: return
        pendingScan = null
        if (error == null) result.success(null) else result.error("scan", error, null)
    }

    private fun cancelPendingScan() { finishScanRequest("扫描已取消") }

    private fun startScan() {
        stopScan()
        devices.clear()
        val currentScanner = adapter?.bluetoothLeScanner ?: throw IllegalStateException("无法启动蓝牙扫描")
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handler.post {
                    if (scanCallback !== this) return@post
                    val name = result.scanRecord?.deviceName?.takeIf { it.isNotBlank() } ?: "未命名设备"
                    val id = result.device.address
                    devices[id] = result.device
                    emit("device", "id" to id, "name" to name, "rssi" to result.rssi)
                }
            }
            override fun onScanFailed(errorCode: Int) {
                handler.post {
                    if (scanCallback !== this) return@post
                    stopScan()
                    emit("error", "message" to "扫描失败（$errorCode），请稍后重试")
                }
            }
        }
        scanner = currentScanner
        scanCallback = callback
        // Some GNSS devices omit service UUIDs in advertisements. Validate GATT
        // services after connecting, and show all discovered BLE devices here.
        currentScanner.startScan(null,
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
        emit("scanning", "value" to true)
        handler.postDelayed(scanTimeout, 15_000)
    }

    private fun stopScan() {
        handler.removeCallbacks(scanTimeout)
        val callback = scanCallback
        scanCallback = null
        try { if (callback != null) scanner?.stopScan(callback) } catch (_: Exception) { }
        scanner = null
        if (callback != null) emit("scanning", "value" to false)
    }

    private fun closeConnection() {
        handler.removeCallbacks(connectTimeout)
        val current = gatt
        gatt = null // Late callbacks must not mutate a new connection.
        phase = "disconnected"
        mtu = 23
        try { current?.disconnect() } catch (_: Exception) { }
        try { current?.close() } catch (_: Exception) { }
    }

    private fun failConnection(message: String) {
        closeConnection()
        state("disconnected", message)
    }

    private fun withGatt(current: BluetoothGatt, action: () -> Unit) {
        handler.post {
            if (disposed || gatt !== current) return@post
            try { action() } catch (error: Exception) {
                failConnection(error.message ?: "蓝牙连接异常，请重新连接")
            }
        }
    }

    private fun discover(current: BluetoothGatt) {
        state("discovering")
        check(current.discoverServices()) { "无法读取设备服务，请重新连接" }
    }

    private val callbacks = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(current: BluetoothGatt, status: Int, newState: Int) = withGatt(current) {
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                failConnection(if (status == BluetoothGatt.GATT_SUCCESS) "设备已断开，请重新连接" else "连接失败（$status），请确认设备未被其他手机占用")
            } else if (newState == BluetoothProfile.STATE_CONNECTED && phase == "connecting") {
                if (mtu >= REQUIRED_MTU) discover(current) else {
                    state("mtu")
                    check(current.requestMtu(REQUIRED_MTU)) { "无法协商蓝牙消息长度，请重新连接" }
                }
            }
        }

        override fun onMtuChanged(current: BluetoothGatt, value: Int, status: Int) = withGatt(current) {
            if (status == BluetoothGatt.GATT_SUCCESS) mtu = value
            if (phase == "mtu") {
                check(status == BluetoothGatt.GATT_SUCCESS && mtu >= REQUIRED_MTU) {
                    "蓝牙消息长度不足（MTU=$mtu），设备需要至少 $REQUIRED_MTU，请重新连接"
                }
                discover(current)
            }
        }

        override fun onServicesDiscovered(current: BluetoothGatt, status: Int) = withGatt(current) {
            if (phase != "discovering") return@withGatt
            check(status == BluetoothGatt.GATT_SUCCESS) { "读取蓝牙服务失败（$status）" }
            val characteristic = current.getService(SERVICE)?.getCharacteristic(GNSS)
                ?: throw IllegalStateException("设备的 GNSS 服务与当前固件协议不匹配，请核对 ESP32 固件")
            check(characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) { "设备不支持 GNSS 通知" }
            val descriptor = characteristic.getDescriptor(CCCD)
                ?: throw IllegalStateException("设备缺少通知配置描述符")
            check(current.setCharacteristicNotification(characteristic, true)) { "无法开启 GNSS 通知" }
            state("subscribing")
            val started = if (Build.VERSION.SDK_INT >= 33) {
                current.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                current.writeDescriptor(descriptor)
            }
            check(started) { "无法订阅 GNSS 通知，请重新连接" }
        }

        override fun onDescriptorWrite(current: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) = withGatt(current) {
            if (phase != "subscribing" || descriptor.uuid != CCCD) return@withGatt
            check(status == BluetoothGatt.GATT_SUCCESS) { "订阅 GNSS 通知失败（$status）" }
            handler.removeCallbacks(connectTimeout)
            state("connected")
        }

        override fun onCharacteristicChanged(current: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            if (characteristic.uuid == GNSS) receive(current, value.copyOf())
        }

        @Deprecated("Used by Android before API 33")
        override fun onCharacteristicChanged(current: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT < 33 && characteristic.uuid == GNSS) {
                @Suppress("DEPRECATION")
                receive(current, characteristic.value?.copyOf() ?: return)
            }
        }
    }

    private fun receive(current: BluetoothGatt, value: ByteArray) = withGatt(current) {
        if (phase == "connected") emit("data", "bytes" to value)
    }

    fun dispose() {
        if (disposed) return
        onCancel(null)
        disposed = true
        handler.removeCallbacksAndMessages(null)
        activity.unregisterReceiver(adapterReceiver)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
