package org.meshscout.mesh_scout

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Radio link-loss alert. Posted only when Flutter reports that an identified radio dropped
 * (never on a manual disconnect). The notification channel's sound respects silent mode and
 * Do Not Disturb; without notification permission a short tone plays only in normal ringer mode.
 */
class LinkAlerts(private val activity: Activity) {
    private val manager = activity.getSystemService(Activity.NOTIFICATION_SERVICE) as NotificationManager
    private val channelId = "meshscout_radio_link"
    private val notificationId = 45

    private fun permitted(): Boolean {
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(channelId)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        return true
    }

    private fun lost(name: String?) {
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(channelId, "Radio connection lost", NotificationManager.IMPORTANCE_HIGH))
        }
        if (permitted()) {
            val intent = Intent(activity, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val pending = PendingIntent.getActivity(activity, notificationId, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, channelId) else Notification.Builder(activity)
            if (Build.VERSION.SDK_INT < 26) builder.setDefaults(Notification.DEFAULT_SOUND).setPriority(Notification.PRIORITY_HIGH)
            manager.notify(notificationId, builder.setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentTitle("MeshScout radio disconnected")
                .setContentText(if (name.isNullOrBlank()) "The Bluetooth link to your radio dropped." else "Lost the Bluetooth link to $name.")
                .setContentIntent(pending).setAutoCancel(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC).build())
            return
        }
        val audio = activity.getSystemService(Activity.AUDIO_SERVICE) as AudioManager
        if (audio.ringerMode == AudioManager.RINGER_MODE_NORMAL) {
            RingtoneManager.getRingtone(activity, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))?.play()
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "lost" -> { lost(call.arguments as? String); result.success(null) }
                "restored" -> { manager.cancel(notificationId); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) { result.error("link_alerts", e.message, null) }
    }
}
