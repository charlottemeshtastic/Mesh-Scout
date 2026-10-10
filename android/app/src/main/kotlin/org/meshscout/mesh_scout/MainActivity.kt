package org.meshscout.mesh_scout

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private val messageAlerts by lazy { MessageAlerts(this) }
    private val scoutFiles by lazy { ScoutFiles(this) }
    private var listener: LocationListener? = null
    private val locations by lazy { getSystemService(LOCATION_SERVICE) as LocationManager }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        // Recover durable native GPS checkpoints before Flutter loads history.
        runCatching { GpsRecordingService.recover(this) }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.meshscout/message_alerts")
            .setMethodCallHandler { call, result -> messageAlerts.handle(call, result) }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.meshscout/files")
            .setMethodCallHandler { call, result -> scoutFiles.handle(call, result) }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.meshscout/radio_session")
            .setMethodCallHandler { call, result ->
                try {
                    val intent = Intent(this, RadioConnectionService::class.java)
                    when (call.method) {
                        "start" -> {
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent)
                            else startService(intent)
                            result.success(null)
                        }
                        "stop" -> { stopService(intent); result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("radio_service", e.message, null) }
            }
        MethodChannel(engine.dartExecutor.binaryMessenger, "org.meshscout/mapping")
            .setMethodCallHandler { call, result ->
                try {
                    val file = File(ScoutStorage.directory(this), "mapping-sessions.json")
                    when (call.method) {
                        "locationEnabled" -> result.success(
                            locations.isProviderEnabled(LocationManager.GPS_PROVIDER))
                        "loadSessions" -> {
                            GpsRecordingService.recover(this)
                            result.success(if (file.exists()) file.readText() else null)
                        }
                        "saveSessions" -> {
                            val json = call.arguments as String
                            JSONArray(json) // Reject invalid session data before replacing the file.
                            val temp = File(ScoutStorage.directory(this), "mapping-sessions.tmp")
                            temp.outputStream().use { stream ->
                                stream.write(json.toByteArray(Charsets.UTF_8))
                                stream.fd.sync()
                            }
                            if (!temp.renameTo(file)) throw Exception("Could not save sessions")
                            GpsRecordingService.clearJournal(this)
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("mapping", e.message, null) }
            }
        EventChannel(engine.dartExecutor.binaryMessenger, "org.meshscout/positions")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    stopLocations()
                    if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
                        sink.error("permission", "Precise location permission is required", null)
                        return
                    }
                    if (!locations.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                        sink.error("gps_off", "Enable GPS/location services", null)
                        return
                    }
                    val options = arguments as? Map<*, *>
                    if (options?.get("background") == true) {
                        try {
                            GpsRecordingService.sink = sink
                            val intent = Intent(this@MainActivity, GpsRecordingService::class.java)
                                .putExtra("started", (options["started"] as Number).toLong())
                            if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        } catch (e: Exception) { GpsRecordingService.sink = null; sink.error("gps_service", e.message, null) }
                        return
                    }
                    val newListener = object : LocationListener {
                        override fun onLocationChanged(location: Location) {
                            sink.success(mapOf("lat" to location.latitude, "lon" to location.longitude,
                                "accuracy" to location.accuracy.toDouble(), "time" to location.time))
                        }
                        override fun onProviderDisabled(provider: String) {
                            sink.error("gps_off", "GPS/location services were turned off", null)
                        }
                        override fun onProviderEnabled(provider: String) {}
                        @Deprecated("Legacy callback")
                        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                    }
                    try {
                        listener = newListener
                        locations.requestLocationUpdates(LocationManager.GPS_PROVIDER, 5000L, 5f, newListener)
                    } catch (e: Exception) {
                        stopLocations()
                        sink.error("gps", e.message, null)
                    }
                }
                override fun onCancel(arguments: Any?) {
                    stopLocations()
                    GpsRecordingService.sink = null
                    GpsRecordingService.stop(this@MainActivity)
                }
            })
    }
    private fun stopLocations() {
        listener?.let { locations.removeUpdates(it) }
        listener = null
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!scoutFiles.activityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        messageAlerts.openMessages = intent.getBooleanExtra("open_messages", false)
    }
    override fun onResume() {
        super.onResume()
        messageAlerts.background = false
        messageAlerts.clear()
    }
    override fun onPause() {
        messageAlerts.background = true
        super.onPause()
    }
    override fun onDestroy() {
        messageAlerts.clear()
        scoutFiles.dispose()
        stopLocations()
        GpsRecordingService.sink = null
        GpsRecordingService.stop(this)
        stopService(Intent(this, RadioConnectionService::class.java))
        super.onDestroy()
    }
}
