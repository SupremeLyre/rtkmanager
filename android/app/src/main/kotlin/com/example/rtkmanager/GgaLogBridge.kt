package com.example.rtkmanager

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.os.Environment
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class GgaLogFileProvider : FileProvider()

class GgaLogBridge(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "rtkmanager/gga_logs")
    private val directory: File by lazy {
        val external = activity.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS)
        File(external ?: activity.filesDir, "GGA").canonicalFile
    }
    private val mqttDirectory: File by lazy {
        val external = activity.getExternalFilesDir(Environment.DIRECTORY_DOCUMENTS)
        File(external ?: activity.filesDir, "MQTT").canonicalFile
    }

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getLogDirectory" -> result.success(directory.path)
                "getMqttLogDirectory" -> result.success(mqttDirectory.path)
                "shareMqttLog" -> {
                    val name = call.argument<String>("name") ?: ""
                    require(Regex("MQTT[0-9]{8}\\.jsonl").matches(name)) { "无效的 MQTT 日志文件名" }
                    val file = File(mqttDirectory, name).canonicalFile
                    require(file.parentFile == mqttDirectory && file.isFile) { "日志文件已不存在" }
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.gga_logs", file)
                    val intent = Intent(Intent.ACTION_SEND).setType("application/x-ndjson")
                        .putExtra(Intent.EXTRA_STREAM, uri).putExtra(Intent.EXTRA_TITLE, name)
                    intent.clipData = ClipData.newRawUri(name, uri)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    activity.startActivity(Intent.createChooser(intent, "分享 MQTT 日志"))
                    result.success(null)
                }
                "openLog", "shareLog" -> {
                    val name = call.argument<String>("name") ?: ""
                    require(Regex("GGA[0-9]{8}\\.txt").matches(name)) { "无效的 GGA 日志文件名" }
                    val file = File(directory, name).canonicalFile
                    require(file.parentFile == directory && file.isFile) { "日志文件已不存在，请刷新列表" }
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.gga_logs", file)
                    val intent = if (call.method == "openLog") {
                        Intent(Intent.ACTION_VIEW).setDataAndType(uri, "text/plain")
                    } else {
                        Intent(Intent.ACTION_SEND).setType("text/plain")
                            .putExtra(Intent.EXTRA_STREAM, uri)
                            .putExtra(Intent.EXTRA_TITLE, name)
                    }
                    intent.clipData = ClipData.newRawUri(name, uri)
                    intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    activity.startActivity(if (call.method == "shareLog") Intent.createChooser(intent, "分享 GGA 日志") else intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: ActivityNotFoundException) {
            result.error("no_handler", "手机上没有可打开 TXT 文件的应用，请安装文本查看器或使用分享", null)
        } catch (exception: Exception) {
            result.error("log_file", exception.message ?: "文件操作失败，请重试", null)
        }
    }

    fun dispose() { channel.setMethodCallHandler(null) }
}
