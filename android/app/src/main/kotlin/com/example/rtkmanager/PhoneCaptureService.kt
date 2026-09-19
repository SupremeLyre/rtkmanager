package com.example.rtkmanager

import android.app.*
import android.content.Intent
import android.os.Build
import android.os.IBinder

class PhoneCaptureService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val engine = PhoneCaptureEngine.get(this)
        if (intent?.action == "stop") {
            engine.worker.post { engine.finish() }
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("phone_capture", "手机原始数据采集", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, PhoneCaptureService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "phone_capture") else Notification.Builder(this)
        startForeground(901, builder.setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("RTK Manager · 传感器采集")
            .setContentText("正在检测或采集 GNSS / IMU / 磁场")
            .setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "停止", stop).build()).build())
        if (intent?.action == "probe") engine.worker.post { engine.probe() }
        return START_NOT_STICKY
    }
    override fun onDestroy() {
        val engine = PhoneCaptureEngine.get(this)
        engine.worker.post {
            if (engine.snapshot["mode"] != "idle") engine.finish("采集服务已结束，已保存收到的数据")
        }
        super.onDestroy()
    }
}
