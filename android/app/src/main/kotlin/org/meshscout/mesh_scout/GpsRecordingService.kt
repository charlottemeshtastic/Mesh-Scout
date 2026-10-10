package org.meshscout.mesh_scout

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import io.flutter.plugin.common.EventChannel
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** A user-started location service; never restarts itself after process death. */
class GpsRecordingService : Service(), LocationListener {
    companion object {
        private var active: GpsRecordingService? = null
        fun stop(context: android.content.Context) {
            active?.finish()
            context.stopService(Intent(context, GpsRecordingService::class.java))
        }
        var running = false
            private set
        var sink: EventChannel.EventSink? = null
        fun recover(context: android.content.Context) {
            if (running) return
            val journal = File(context.filesDir, "gps-in-progress.json")
            if (!journal.exists()) return
            val session = JSONObject(journal.readText())
            val points = session.getJSONArray("points")
            if (points.length() == 0) { journal.delete(); return }
            session.put("ended", points.getJSONObject(points.length() - 1).getString("time"))
                .put("name", "Recovered interrupted recording").put("observations", JSONArray())
            val root = ScoutStorage.directory(context)
            val history = File(root, "mapping-sessions.json")
            val existing = if (history.exists()) JSONArray(history.readText()) else JSONArray()
            val updated = JSONArray()
            if ((0 until existing.length()).none { existing.getJSONObject(it).getString("id") == session.getString("id") }) updated.put(session)
            for (i in 0 until existing.length()) updated.put(existing.getJSONObject(i))
            val temp = File(root, "mapping-sessions.tmp")
            ScoutStorage.write(temp, updated.toString())
            require(temp.renameTo(history))
            require(journal.delete())
        }
        fun clearJournal(context: android.content.Context) {
            if (!running) File(context.filesDir, "gps-in-progress.json").delete()
        }
    }
    private val locations by lazy { getSystemService(LOCATION_SERVICE) as LocationManager }
    private var session: JSONObject? = null
    private var lastTime = 0L
    private fun iso(time: Long): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date(time))
    override fun onCreate() { super.onCreate(); active = this }
    private fun finish() {
        locations.removeUpdates(this)
        running = false
        session = null
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true)
        stopSelf()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (running) return START_NOT_STICKY
        try {
            val started = intent?.getLongExtra("started", 0L) ?: 0L
            require(started > 0)
            val channelId = "meshscout_gps"
            if (Build.VERSION.SDK_INT >= 26) (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(NotificationChannel(channelId, "GPS route recording", NotificationManager.IMPORTANCE_LOW))
            val launch = PendingIntent.getActivity(this, 44, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, channelId) else Notification.Builder(this)
            val notification = builder.setSmallIcon(android.R.drawable.ic_menu_mylocation)
                .setContentTitle("MeshScout is recording your route")
                .setContentText("GPS recording continues while locked. Open MeshScout to stop and save.")
                .setContentIntent(launch).setOngoing(true).build()
            if (Build.VERSION.SDK_INT >= 29) startForeground(44, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            else startForeground(44, notification)
            session = JSONObject().put("id", started.toString()).put("started", iso(started / 1000)).put("points", JSONArray())
            lastTime = started / 1000 - 5000
            running = true
            locations.requestLocationUpdates(LocationManager.GPS_PROVIDER, 5000L, 5f, this)
        } catch (e: Exception) { sink?.error("gps", e.message, null); finish() }
        return START_NOT_STICKY
    }
    override fun onLocationChanged(location: Location) {
        val data = session ?: return
        if (!location.hasAccuracy() || location.accuracy < 0 || location.accuracy > 100) return
        val points = data.getJSONArray("points")
        if (points.length() >= 10000) { sink?.endOfStream(); finish(); return }
        if (location.time <= lastTime) return
        lastTime = location.time
        try {
            points.put(JSONObject().put("lat", location.latitude).put("lon", location.longitude)
                .put("accuracy", location.accuracy.toDouble()).put("time", iso(location.time)))
            val temp = File(filesDir, "gps-in-progress.tmp")
            ScoutStorage.write(temp, data.toString())
            require(temp.renameTo(File(filesDir, "gps-in-progress.json")))
            sink?.success(mapOf("lat" to location.latitude, "lon" to location.longitude, "accuracy" to location.accuracy.toDouble(), "time" to location.time))
        } catch (e: Exception) { sink?.error("gps_save", "Could not checkpoint GPS route", null); finish() }
    }
    override fun onProviderDisabled(provider: String) { sink?.error("gps_off", "GPS/location services were turned off", null); finish() }
    override fun onProviderEnabled(provider: String) {}
    @Deprecated("Legacy callback")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    override fun onDestroy() {
        locations.removeUpdates(this)
        if (active === this) { active = null; running = false }
        session = null
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
