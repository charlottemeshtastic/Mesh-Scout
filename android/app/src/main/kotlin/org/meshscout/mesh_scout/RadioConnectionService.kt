package org.meshscout.mesh_scout

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** Keeps the process hosting Flutter's BLE connection eligible during app switching. */
class RadioConnectionService : Service() {
    override fun onCreate() {
        super.onCreate()
        val channelId = "meshscout_radio"
        if (Build.VERSION.SDK_INT >= 26) {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(NotificationChannel(channelId, "Radio connection",
                    NotificationManager.IMPORTANCE_LOW))
        }
        val launch = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channelId)
            else Notification.Builder(this)
        val notification = builder.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("MeshScout radio connection")
            .setContentText("Radio session active. Open MeshScout to disconnect.")
            .setContentIntent(pending).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(42, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else startForeground(42, notification)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_NOT_STICKY
    override fun onBind(intent: Intent?): IBinder? = null
}
