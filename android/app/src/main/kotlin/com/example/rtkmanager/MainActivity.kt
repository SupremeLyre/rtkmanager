package com.example.rtkmanager

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var gnssBle: GnssBleBridge? = null
    private var ggaLogs: GgaLogBridge? = null
    private var phoneCapture: PhoneCaptureBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        gnssBle = GnssBleBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        ggaLogs = GgaLogBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        phoneCapture = PhoneCaptureBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        gnssBle?.onPermissionsResult(code)
        phoneCapture?.onPermissionsResult(code)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        gnssBle?.onActivityResult(requestCode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        gnssBle?.dispose()
        gnssBle = null
        ggaLogs?.dispose()
        ggaLogs = null
        phoneCapture?.dispose()
        phoneCapture = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
