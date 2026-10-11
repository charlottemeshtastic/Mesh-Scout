package org.meshscout.mesh_scout

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/** The visible BLE session can resume read-only monitoring after a system restart. */
class RadioConnectionService : Service() {
    companion object {
        private var active: RadioConnectionService? = null
        fun takeOver() { active?.monitor?.close(); active?.monitor = null }
    }
    private var monitor: RecoveredRadioMonitor? = null
    private var eligible = false
    private fun notification(text: String): Notification {
        val pending = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "meshscout_radio") else Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.stat_sys_data_bluetooth).setContentTitle("MeshScout radio connection")
            .setContentText(text).setContentIntent(pending).setOngoing(true).build()
    }
    override fun onCreate() {
        super.onCreate(); active = this
        if (Build.VERSION.SDK_INT >= 26) (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(NotificationChannel("meshscout_radio", "Radio connection", NotificationManager.IMPORTANCE_LOW))
        if (Build.VERSION.SDK_INT >= 31 && checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) { stopSelf(); return }
        val value = notification("Radio session active. Open MeshScout to disconnect.")
        if (Build.VERSION.SDK_INT >= 29) startForeground(42, value, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(42, value)
        eligible = true
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!eligible) { stopSelf(); return START_NOT_STICKY }
        if (intent == null && monitor == null) {
            monitor = RecoveredRadioMonitor(this) { text ->
                (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(42, notification(text))
            }.also { it.start() }
        } else if (intent != null) {
            takeOver()
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(42, notification("Radio session active. Open MeshScout to disconnect."))
        }
        return START_STICKY
    }
    override fun onDestroy() { takeOver(); if (active === this) active = null; super.onDestroy() }
    override fun onBind(intent: Intent?): IBinder? = null
}
