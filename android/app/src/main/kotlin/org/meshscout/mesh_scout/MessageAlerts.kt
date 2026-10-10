package org.meshscout.mesh_scout

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Generic waiting-mail alerts: never retrieve queue items or expose message bodies/keys. */
class MessageAlerts(private val activity: Activity) {
    private val manager = activity.getSystemService(Activity.NOTIFICATION_SERVICE) as NotificationManager
    private val preferences = activity.getSharedPreferences("message-alerts", Activity.MODE_PRIVATE)
    private val channelId = "meshscout_messages"
    var openMessages = activity.intent.getBooleanExtra("open_messages", false)
    var background = false
    private var posted = false
    private fun permitted(): Boolean {
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(channelId)?.importance == NotificationManager.IMPORTANCE_NONE) return false
        return true
    }
    fun clear() { manager.cancel(43); posted = false }
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "consumeOpen" -> { val open = openMessages; openMessages = false; activity.intent.removeExtra("open_messages"); result.success(open) }
                "load" -> result.success(preferences.getBoolean("enabled", false) && permitted())
                "configure" -> {
                    val requested = call.arguments as? Boolean ?: false
                    if (requested && Build.VERSION.SDK_INT >= 26) {
                        manager.createNotificationChannel(NotificationChannel(channelId, "Messages waiting", NotificationManager.IMPORTANCE_DEFAULT))
                    }
                    val enabled = requested && permitted()
                    check(preferences.edit().putBoolean("enabled", enabled).commit()) { "Could not save alert preference" }
                    if (!enabled) clear()
                    result.success(enabled)
                }
                "waiting" -> {
                    if (background && !posted && preferences.getBoolean("enabled", false) && permitted()) {
                        val intent = Intent(activity, MainActivity::class.java).putExtra("open_messages", true).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        val pending = PendingIntent.getActivity(activity, 43, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, channelId) else Notification.Builder(activity)
                        manager.notify(43, builder.setSmallIcon(android.R.drawable.stat_notify_chat)
                            .setContentTitle("MeshScout messages waiting")
                            .setContentText("Open Nodes → Messages to fetch from your radio.")
                            .setContentIntent(pending).setAutoCancel(true).setOnlyAlertOnce(true)
                            .setVisibility(Notification.VISIBILITY_PRIVATE).build())
                        posted = true
                    }
                    result.success(null)
                }
                "clear" -> { clear(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) { result.error("message_alerts", e.message, null) }
    }
}
