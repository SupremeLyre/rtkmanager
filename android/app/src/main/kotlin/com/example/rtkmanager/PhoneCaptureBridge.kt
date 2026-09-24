package com.example.rtkmanager

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.FileProvider
import io.flutter.plugin.common.*
import java.io.File

class PhoneCaptureBridge(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val methods = MethodChannel(messenger, "rtkmanager/phone_capture")
    private val events = EventChannel(messenger, "rtkmanager/phone_capture_events")
    private val engine = PhoneCaptureEngine.get(activity)
    private val main = Handler(Looper.getMainLooper())
    private var permissionResult: MethodChannel.Result? = null
    private var disposed = false
    init { methods.setMethodCallHandler(this); events.setStreamHandler(this) }
    override fun onListen(args: Any?, sink: EventChannel.EventSink) {
        engine.listener = { sink.success(it) }; sink.success(engine.snapshot)
    }
    override fun onCancel(args: Any?) { engine.listener = null }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(engine.snapshot)
                "probe" -> {
                    val notificationsMissing = Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    if (activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED || notificationsMissing) {
                        check(permissionResult == null) { "请先完成定位权限选择" }
                        permissionResult = result
                        val permissions = mutableListOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                        if (notificationsMissing) permissions.add(Manifest.permission.POST_NOTIFICATIONS)
                        activity.requestPermissions(permissions.toTypedArray(), 904)
                    } else { beginProbe(); result.success(null) }
                }
                "start" -> engine.worker.post {
                    try {
                        engine.start((call.argument<List<String>>("sensors") ?: emptyList()).toSet(),
                            call.argument<Int>("imuHz") ?: 100, call.argument<Int>("magHz") ?: 50)
                        main.post { result.success(engine.snapshot) }
                    } catch (e: Exception) { main.post { result.error("capture", e.message, null) } }
                }
                "stop" -> engine.worker.post { engine.finish(); main.post { result.success(engine.snapshot) } }
                "sessions" -> engine.worker.post {
                    val sessions = engine.root.listFiles()?.filter { it.isDirectory && it.name.startsWith("Capture_") }
                        ?.sortedByDescending { it.name }?.map { dir -> mapOf("name" to dir.name, "path" to dir.path,
                            "files" to (dir.listFiles()?.filter { it.isFile }?.map { it.path } ?: emptyList<String>())) } ?: emptyList()
                    main.post { result.success(sessions) }
                }
                "decodeDirectory" -> {
                    val dir = File(engine.root, "Decoded"); check(dir.isDirectory || dir.mkdirs())
                    result.success(dir.path)
                }
                "share" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    engine.worker.post {
                        try {
                            check(engine.snapshot["mode"] != "recording") { "请先停止采集再分享文件" }
                            val file = CaptureShareFiles.prepare(engine.root, activity.cacheDir, paths)
                            main.post {
                                try {
                                    check(!disposed && !activity.isFinishing && !activity.isDestroyed) { "页面已关闭，请重新分享" }
                                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.gga_logs", file)
                                    // WeChat accepts a single file but not SEND_MULTIPLE with
                                    // binary attachments. Multiple files are streamed into a ZIP.
                                    val intent = Intent(Intent.ACTION_SEND)
                                        .setType(if (file.extension == "zip") "application/zip" else "application/octet-stream")
                                        .putExtra(Intent.EXTRA_STREAM, uri)
                                        .putExtra(Intent.EXTRA_TITLE, file.name)
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    intent.clipData = ClipData.newRawUri(file.name, uri)
                                    activity.startActivity(Intent.createChooser(intent, "分享采集数据"))
                                    result.success(null)
                                } catch (e: Exception) { result.error("share", e.message ?: "分享失败", null) }
                            }
                        } catch (e: Exception) { main.post { result.error("share", e.message ?: "文件打包失败", null) } }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) { result.error("capture", e.message ?: "采集操作失败", null) }
    }
    private fun beginProbe() {
        val intent = Intent(activity, PhoneCaptureService::class.java).setAction("probe")
        if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent) else activity.startService(intent)
    }
    fun onPermissionsResult(code: Int) {
        if (code != 904) return
        val result = permissionResult ?: return; permissionResult = null
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            result.error("permission", "原始 GNSS 需要精确位置权限，请在系统设置中授权", null)
        } else try { beginProbe(); result.success(null) } catch (e: Exception) { result.error("capture", e.message, null) }
    }
    fun dispose() {
        disposed = true
        permissionResult?.error("closed", "页面已关闭", null); permissionResult = null
        engine.listener = null; methods.setMethodCallHandler(null); events.setStreamHandler(null)
    }
}
