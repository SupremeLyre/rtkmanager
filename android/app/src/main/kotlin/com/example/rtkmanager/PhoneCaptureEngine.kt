package com.example.rtkmanager

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.*
import android.location.*
import android.os.*
import org.json.JSONObject
import java.io.*
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Executor
import kotlin.math.*

@SuppressLint("MissingPermission")
class PhoneCaptureEngine private constructor(private val context: Context) : SensorEventListener {
    companion object {
        @Volatile private var instance: PhoneCaptureEngine? = null
        fun get(context: Context): PhoneCaptureEngine = instance ?: synchronized(this) {
            instance ?: PhoneCaptureEngine(context.applicationContext).also { instance = it }
        }
    }
    val worker = Handler(HandlerThread("phone-raw-capture").apply { start() }.looper)
    private val main = Handler(Looper.getMainLooper())
    private val location = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    val root = File(context.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS) ?: context.filesDir, "PhoneCapture")
    @Volatile var snapshot: Map<String, Any?> = mapOf("mode" to "idle", "message" to "请先检测传感器（建议在室外）")
        private set
    @Volatile var listener: ((Map<String, Any?>) -> Unit)? = null
    private var mode = "idle"
    private var message = "请先检测传感器（建议在室外）"
    private var selected = setOf<String>()
    private val devices = linkedMapOf<String, Sensor?>()
    private val seen = mutableMapOf<String, Long>()
    private val counts = mutableMapOf<String, Long>()
    private var gnssSeen = 0L
    private var phaseCount = 0
    private var observationCount = 0
    private var unsupportedCount = 0
    private val sync = GnssTimeSync()
    private var leap = 18
    private var leapSource = "IERS table: 2017-01-01 (18 s); GPST TLV is authoritative"
    private val rtcm = RtcmMsm7()
    private var started = 0L
    private var startGps = 0L
    private var lastClockLine = ""
    private var probeStarted = 0L
    private var tid = 0
    private var session: File? = null
    private val outputs = mutableMapOf<String, BufferedOutputStream>()
    private var wake: PowerManager.WakeLock? = null
    private var requestedHz = 100
    private val fixListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {}
        override fun onProviderDisabled(provider: String) {
            if (provider == LocationManager.GPS_PROVIDER) finish("系统定位已关闭，采集已停止")
        }
        @Deprecated("Legacy callback") override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
    }
    private val gnssCallback = object : GnssMeasurementsEvent.Callback() {
        override fun onGnssMeasurementsReceived(event: GnssMeasurementsEvent) {
            guarded { gnss(event) }
        }
        @Deprecated("Legacy callback") override fun onStatusChanged(status: Int) {
            if (status == STATUS_NOT_SUPPORTED) { message = "手机未提供 GNSS 原始测量"; publish() }
        }
    }
    private val heartbeat = object : Runnable {
        override fun run() {
            guarded {
                val now = SystemClock.elapsedRealtimeNanos()
                if (mode == "recording") {
                    if (sync.at(now) == null) { finish("GNSS 时钟超过 10 秒未更新，已停止并保存文件"); return@guarded }
                    val stalled = selected.firstOrNull { key -> key != "gnss" && now - (seen[key] ?: 0) > 5000000000L }
                    if (stalled != null) { finish("$stalled 数据流中断，已停止并保存文件"); return@guarded }
                    outputs.values.forEach { it.flush() }
                } else if (mode == "probing" && now - probeStarted > 60000000000L) {
                    finish("检测已结束；请在室外重新检测，再选择传感器")
                    return@guarded
                }
                publish()
                if (mode != "idle") worker.postDelayed(this, 500)
            }
        }
    }

    fun probe() = guarded {
        if (mode == "recording") return@guarded
        unregister()
        sync.clear(); seen.clear(); gnssSeen = 0; counts.clear(); phaseCount = 0; observationCount = 0
        require(Build.VERSION.SDK_INT >= 29) { "精确同步需要 Android 10 及 GNSS elapsedRealtime 时间戳支持" }
        require(location.isProviderEnabled(LocationManager.GPS_PROVIDER)) { "请先开启手机系统定位" }
        devices.clear()
        devices["accel"] = sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER_UNCALIBRATED)
            ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        devices["gyro"] = sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE_UNCALIBRATED)
            ?: sensors.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        devices["mag"] = sensors.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD_UNCALIBRATED)
            ?: sensors.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)
        mode = "probing"; probeStarted = SystemClock.elapsedRealtimeNanos()
        message = "正在检测实际数据；请在室外等待 GNSS 时钟"
        devices.forEach { (_, sensor) -> sensor?.let { sensors.registerListener(this, it, 20000, worker) } }
        location.requestLocationUpdates(LocationManager.GPS_PROVIDER, 0, 0f, fixListener, worker.looper)
        val registered = if (Build.VERSION.SDK_INT >= 31) {
            location.registerGnssMeasurementsCallback(GnssMeasurementRequest.Builder().setFullTracking(true).build(),
                Executor { worker.post(it) }, gnssCallback)
        } else location.registerGnssMeasurementsCallback(gnssCallback, worker)
        require(registered) { "GNSS 原始测量接口注册失败" }
        worker.removeCallbacks(heartbeat); worker.post(heartbeat)
    }

    fun start(keys: Set<String>, hz: Int) {
        check(mode == "probing") { "请先重新检测传感器" }
        require(keys.isNotEmpty() && keys.all { it in setOf("gnss", "accel", "gyro", "mag") }) { "请选择可用传感器" }
        require(hz in listOf(25, 50, 100, 200))
        val now = SystemClock.elapsedRealtimeNanos()
        check(sync.at(now) != null && now - sync.elapsedNs < 3000000000L) { "尚无新鲜的 GNSS 统一时间，请在室外重新检测" }
        keys.forEach { key -> check(available(key, now)) { "$key 尚无有效数据，不能开始采集" } }
        selected = keys; requestedHz = hz
        root.mkdirs()
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss_SSS", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date())
        val dir = File(root, "Capture_$stamp")
        check(dir.mkdir()) { "无法创建采集目录" }
        session = dir; counts.clear(); tid = 0; rtcm.reset(); started = now
        startGps = sync.at(now)!!
        try {
            fun open(name: String) { outputs[name] = BufferedOutputStream(FileOutputStream(File(dir, name)), 65536) }
            open("clock.csv")
            line("clock.csv", "gpsNanos,elapsedRealtimeNanos,elapsedUncertaintyNanos,timeNanos,fullBiasNanos,biasNanos,clockDiscontinuity,leapSeconds,leapSource")
            // Persist the pre-start anchor too, so the first sensor samples remain auditable.
            line("clock.csv", lastClockLine)
            if ("gnss" in keys) {
                open("observations.rtcm3"); open("gnss_raw.csv")
                line("gnss_raw.csv", "gpsNanos,elapsedRealtimeNanos,constellation,svid,codeType,frequencyHz,timeOffsetNanos,state,receivedSvTimeNanos,svTimeUncertaintyNanos,cn0DbHz,pseudorangeRateMps,rateUncertaintyMps,adrState,adrMeters,adrUncertaintyMeters,pseudorangeMeters,carrierCyclesFromAdr,dopplerHz,msmSignal,fullIsbNanos,satelliteIsbNanos")
            }
            if (keys.any { it != "gnss" }) {
                open("sensors_raw.csv")
                line("sensors_raw.csv", "sensor,gpsNanos,elapsedRealtimeNanos,accuracy,x,y,z,biasX,biasY,biasZ")
            }
            if ("accel" in keys || "gyro" in keys) open("imu.bin")
            if ("mag" in keys) open("mag.bin")
            metadata("recording")
            sensors.unregisterListener(this)
            keys.filter { it != "gnss" }.forEach { key ->
                check(sensors.registerListener(this, devices.getValue(key), 1000000 / hz, worker)) { "$key 无法启动" }
            }
            wake = (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rtkmanager:rawCapture").apply { acquire() }
            mode = "recording"; message = "正在采集（GPS 时间）；点击停止后完成保存"
            publish()
        } catch (e: Exception) { finish("启动失败：${e.message}"); throw e }
    }

    fun finish(reason: String = "采集已停止，文件已保存") {
        val wasRecording = mode == "recording" || outputs.isNotEmpty()
        mode = "idle"; message = reason
        unregister()
        var failure: String? = null
        outputs.values.forEach { try { it.close() } catch (e: Exception) { failure = e.message } }
        outputs.clear()
        if (wake?.isHeld == true) wake?.release()
        wake = null
        if (wasRecording) try { metadata(if (failure == null) reason else "写入失败：$failure") } catch (e: Exception) { failure = e.message }
        if (failure != null) message = "文件写入失败：$failure"
        publish()
        context.stopService(android.content.Intent(context, PhoneCaptureService::class.java))
    }

    private fun unregister() {
        worker.removeCallbacks(heartbeat)
        sensors.unregisterListener(this)
        runCatching { location.unregisterGnssMeasurementsCallback(gnssCallback) }
        runCatching { location.removeUpdates(fixListener) }
    }
    private fun guarded(block: () -> Unit) {
        try { block() } catch (e: Exception) { finish("采集异常：${e.message}") }
    }
    private fun available(key: String, now: Long): Boolean = if (key == "gnss")
        gnssSeen > 0 && now - gnssSeen < 3000000000L else devices[key] != null && now - (seen[key] ?: 0) < 2000000000L

    private fun publish() {
        val now = SystemClock.elapsedRealtimeNanos()
        val ready = mode != "idle" && sync.at(now) != null && now - sync.elapsedNs < 3000000000L
        snapshot = mapOf("mode" to mode, "message" to message, "timeReady" to ready,
            "path" to (session?.path ?: root.path), "phaseCount" to phaseCount, "observationCount" to observationCount,
            "unsupportedCount" to unsupportedCount, "counts" to counts.toMap(), "selected" to selected.toList(),
            "sensors" to (listOf("gnss") + devices.keys).associateWith { key -> mapOf(
                "available" to (mode != "idle" && available(key, now)),
                "detail" to if (key == "gnss") "RTCM3 MSM7；有效观测 $observationCount，载波 $phaseCount，未编码 $unsupportedCount" else
                    (devices[key]?.let { "${it.name} · ${if (it.type in listOf(35, 16, 14)) "未校准原始值" else "系统校准值"}" } ?: "未发现对应硬件")) })
        val value = snapshot
        main.post { listener?.invoke(value) }
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (mode == "idle") return
        guarded {
            val key = devices.entries.firstOrNull { it.value == event.sensor }?.key ?: return@guarded
            if (event.values.size < 3 || event.values.take(3).any { !it.isFinite() }) return@guarded
            seen[key] = event.timestamp
            if (mode != "recording" || key !in selected || event.timestamp < started) return@guarded
            val gps = sync.at(event.timestamp) ?: return@guarded
            val id = when (key) { "accel" -> 0x10; "gyro" -> 0x20; else -> 0x30 }
            val file = if (key == "mag") "mag.bin" else "imu.bin"
            outputs.getValue(file).write(CaptureFormats.sensorFrame(tid++ and 65535, gps, leap, id, event.values))
            val v = (0..5).joinToString(",") { if (it < event.values.size) event.values[it].toString() else "" }
            line("sensors_raw.csv", "$key,$gps,${event.timestamp},${event.accuracy},$v")
            counts[key] = (counts[key] ?: 0) + 1
        }
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun gnss(event: GnssMeasurementsEvent) {
        if (mode == "idle") return
        val c = event.clock
        if (!c.hasFullBiasNanos() || Build.VERSION.SDK_INT < 29 || !c.hasElapsedRealtimeNanos()) {
            message = "未取得 GNSS 完整时钟及采样时间戳，暂不能同步采集"; return
        }
        val bias = if (c.hasBiasNanos()) c.biasNanos else 0.0
        if (!bias.isFinite()) return
        // Subtract integer nanoseconds before any conversion to Double (no 1e18 precision loss).
        val gps = c.timeNanos - c.fullBiasNanos - bias.roundToLong()
        if (gps <= 0 || c.elapsedRealtimeNanos <= 0) return
        if (c.hasLeapSecond()) { leap = c.leapSecond; leapSource = "GnssClock" }
        val changed = sync.update(gps, c.elapsedRealtimeNanos, c.hardwareClockDiscontinuityCount)
        if (changed) {
            rtcm.reset()
            if (mode == "recording") { finish("GNSS 时钟发生跳变，已停止并保存；请重新检测后采集"); return }
        }
        lastClockLine = "$gps,${c.elapsedRealtimeNanos},${if(c.hasElapsedRealtimeUncertaintyNanos()) c.elapsedRealtimeUncertaintyNanos else ""},${c.timeNanos},${c.fullBiasNanos},$bias,${c.hardwareClockDiscontinuityCount},$leap,$leapSource"
        if (mode == "recording") line("clock.csv", lastClockLine)
        val obs = mutableListOf<PhoneObservation>()
        val epoch = ((gps + 500000) / 1000000) * 1000000
        for (m in event.measurements) {
            val frequency = if (m.hasCarrierFrequencyHz()) m.carrierFrequencyHz.toDouble() else Double.NaN
            val code = m.codeType
            val sig = PhoneGnssMath.signal(m.constellationType, frequency, code)
            val pr = PhoneGnssMath.pseudorange(gps, m.timeOffsetNanos, m.receivedSvTimeNanos, m.constellationType, m.state, leap)
            val adr = m.accumulatedDeltaRangeMeters.takeIf { m.accumulatedDeltaRangeState and 1 != 0 && it.isFinite() }
            val rate = m.pseudorangeRateMetersPerSecond.takeIf { it.isFinite() && m.pseudorangeRateUncertaintyMetersPerSecond.isFinite() }
            val sat = when (m.constellationType) { 2 -> m.svid - 119; 4 -> m.svid - 192; else -> m.svid }
            if (mode == "recording" && "gnss" in selected) {
                val isb = if (Build.VERSION.SDK_INT >= 30 && m.hasFullInterSignalBiasNanos()) m.fullInterSignalBiasNanos else ""
                val svIsb = if (Build.VERSION.SDK_INT >= 30 && m.hasSatelliteInterSignalBiasNanos()) m.satelliteInterSignalBiasNanos else ""
                // RINEX/RTCM phase uses positive ADR/lambda; Doppler = -range-rate/lambda.
                line("gnss_raw.csv", listOf(gps, c.elapsedRealtimeNanos, m.constellationType, m.svid, code,
                    frequency, m.timeOffsetNanos, m.state, m.receivedSvTimeNanos, m.receivedSvTimeUncertaintyNanos,
                    m.cn0DbHz, m.pseudorangeRateMetersPerSecond, m.pseudorangeRateUncertaintyMetersPerSecond,
                    m.accumulatedDeltaRangeState, m.accumulatedDeltaRangeMeters, m.accumulatedDeltaRangeUncertaintyMeters,
                    pr ?: "", if (adr != null && frequency.isFinite()) adr * frequency / CaptureFormats.C else "",
                    if (rate != null && frequency.isFinite()) -rate * frequency / CaptureFormats.C else "", sig ?: "", isb, svIsb).joinToString(","))
            }
            if (pr == null || sig == null || sat !in 1..64 || !m.cn0DbHz.isFinite()) continue
            var channel = 0
            if (m.constellationType == 3) {
                val l1 = frequency > 1400000000
                channel = ((frequency - if (l1) 1602000000.0 else 1246000000.0) / if (l1) 562500.0 else 437500.0).roundToInt()
                if (channel !in -7..6) continue
            }
            // Project each measurement to the millisecond MSM epoch using its observed rate.
            val dt = (epoch - gps) * 1e-9 - m.timeOffsetNanos * 1e-9
            if (rate == null && abs(dt) > .000001) continue
            val correction = (rate ?: 0.0) * dt
            obs.add(PhoneObservation(m.constellationType, sat, sig, frequency, pr + correction,
                adr?.plus(correction), rate, m.cn0DbHz, m.accumulatedDeltaRangeState, channel))
        }
        observationCount = obs.size; phaseCount = obs.count { it.phaseMeters != null }
        unsupportedCount = event.measurements.size - obs.size
        if (obs.isNotEmpty()) gnssSeen = c.elapsedRealtimeNanos
        if (mode == "recording" && "gnss" in selected) {
            rtcm.encode(epoch, leap, obs).forEach { outputs.getValue("observations.rtcm3").write(it) }
            counts["gnss"] = (counts["gnss"] ?: 0) + 1
        }
    }
    private fun line(file: String, value: String) { outputs.getValue(file).write((value + "\n").toByteArray(Charsets.UTF_8)) }
    private fun metadata(status: String) {
        val json = JSONObject().put("formatVersion", 1).put("status", status)
            .put("device", "${Build.MANUFACTURER} ${Build.MODEL}").put("androidSdk", Build.VERSION.SDK_INT)
            .put("selected", selected.joinToString(",")).put("requestedSensorHz", requestedHz)
            .put("timeSystem", "GPST; TLV 0x52=u16 week + u64 nanoseconds of week; little endian")
            .put("startGpsNanos", startGps).put("leapSeconds", leap).put("leapSource", leapSource)
            .put("axes", "Android device frame: x right, y top, z out of screen; no screen rotation")
            .put("imuUnits", "0x10: g * 1e-6; 0x20: deg/s * 1e-6; independent timestamped samples")
            .put("magUnits", "0x30: microtesla * 1e-3; 0x81-0x83 reserved for firmware debug")
            .put("rawCsvUnits", "Android SI units: m/s^2, rad/s, microtesla; bias values preserved if reported")
            .put("rtcm", "MSM7 1077/1087/1097/1107/1117/1127/1137; station 0; observations only, no ephemerides")
            .put("phase", "ADR/lambda with constant integer-cycle offset per continuous arc; original ADR in gnss_raw.csv; unavailable phase encoded invalid")
            .put("sensors", JSONObject(devices.mapValues { (_, s) -> s?.let { "${it.name}; type=${it.type}; resolution=${it.resolution}; minDelayUs=${it.minDelay}" } }))
            .put("counts", JSONObject(counts as Map<*, *>))
        File(session!!, "session.json").writeText(json.toString(2))
    }
}
