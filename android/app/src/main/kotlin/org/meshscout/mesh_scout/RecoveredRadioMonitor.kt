package org.meshscout.mesh_scout

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.bluetooth.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Read-only recovery monitoring. Queue retrieval and all settings remain in Flutter. */
@Suppress("DEPRECATION", "MissingPermission")
class RecoveredRadioMonitor(private val context: Context, private val status: (String) -> Unit) : BluetoothGattCallback() {
    private val handler = Handler(Looper.getMainLooper())
    private val serviceId = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    private val rxId = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    private val txId = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
    private var gatt: BluetoothGatt? = null
    private var target: String? = null
    private var attempt = 0
    private var stage = 0
    private var stopped = false
    private var alerted = false
    private val deadline = Runnable { if (!stopped && stage != 3) retry() }
    fun start() {
        try {
            val settings = File(ScoutStorage.directory(context), "settings.json")
            require(settings.exists())
            val data = JSONObject(settings.readText())
            require(data.optBoolean("resumeMonitoring") && data.optBoolean("autoReconnect"))
            val id = data.getJSONObject("preferredRadio").getString("id")
            require(BluetoothAdapter.checkBluetoothAddress(id))
            if (Build.VERSION.SDK_INT >= 31) require(context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED)
            target = id
            connect()
        } catch (_: Exception) { status("Monitoring interrupted. Open MeshScout to reconnect.") }
    }
    private fun connect() {
        if (stopped || attempt >= 5) { status("Recovery could not reconnect. Open MeshScout."); return }
        attempt++
        stage = 0
        try {
            val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            val device = manager.adapter.getRemoteDevice(target!!)
            status("Recovering radio monitoring ($attempt/5)…")
            gatt = device.connectGatt(context, false, this, BluetoothDevice.TRANSPORT_LE)
            handler.postDelayed(deadline, 30000)
        } catch (_: Exception) { retry() }
    }
    private fun retry() {
        if (stopped) return
        handler.removeCallbacksAndMessages(null)
        gatt?.close(); gatt = null
        handler.postDelayed({ connect() }, 6000)
    }
    fun close() {
        stopped = true
        handler.removeCallbacksAndMessages(null)
        gatt?.disconnect(); gatt?.close(); gatt = null
    }
    private fun current(value: BluetoothGatt) = !stopped && value === gatt
    override fun onConnectionStateChange(value: BluetoothGatt, result: Int, state: Int) {
        handler.post {
            if (!current(value)) return@post
            if (result == BluetoothGatt.GATT_SUCCESS && state == BluetoothProfile.STATE_CONNECTED) {
                if (!value.requestMtu(185)) retry()
            } else if (state == BluetoothProfile.STATE_DISCONNECTED || result != BluetoothGatt.GATT_SUCCESS) retry()
        }
    }
    override fun onMtuChanged(value: BluetoothGatt, mtu: Int, result: Int) {
        handler.post { if (current(value)) {
            if (result != BluetoothGatt.GATT_SUCCESS || mtu < 93 || !value.discoverServices()) retry()
        } }
    }
    override fun onServicesDiscovered(value: BluetoothGatt, result: Int) {
        handler.post { if (current(value)) {
            try {
                require(result == BluetoothGatt.GATT_SUCCESS)
                val service = value.getService(serviceId) ?: error("Missing service")
                val tx = service.getCharacteristic(txId) ?: error("Missing notifications")
                val rx = service.getCharacteristic(rxId) ?: error("Missing write characteristic")
                require(rx.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0)
                require(tx.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0)
                require(value.setCharacteristicNotification(tx, true))
                val descriptor = tx.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")) ?: error("Missing subscription")
                if (Build.VERSION.SDK_INT >= 33) require(value.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == 0)
                else { descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; require(value.writeDescriptor(descriptor)) }
            } catch (_: Exception) { retry() }
        } }
    }
    override fun onDescriptorWrite(value: BluetoothGatt, descriptor: BluetoothGattDescriptor, result: Int) {
        handler.post { if (current(value)) {
            if (result != BluetoothGatt.GATT_SUCCESS) retry()
            else { stage = 1; write(value, RecoveryProtocol.appStart()) }
        } }
    }
    private fun write(value: BluetoothGatt, bytes: ByteArray) {
        try {
            val rx = value.getService(serviceId).getCharacteristic(rxId)
            if (Build.VERSION.SDK_INT >= 33) require(value.writeCharacteristic(rx, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == 0)
            else { rx.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT; rx.value = bytes; require(value.writeCharacteristic(rx)) }
        } catch (_: Exception) { retry() }
    }
    override fun onCharacteristicWrite(value: BluetoothGatt, characteristic: BluetoothGattCharacteristic, result: Int) {
        handler.post { if (current(value) && result != BluetoothGatt.GATT_SUCCESS) retry() }
    }
    override fun onCharacteristicChanged(value: BluetoothGatt, characteristic: BluetoothGattCharacteristic, bytes: ByteArray) {
        if (characteristic.uuid == txId) receive(value, bytes.copyOf())
    }
    override fun onCharacteristicChanged(value: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
        if (Build.VERSION.SDK_INT < 33 && characteristic.uuid == txId) receive(value, characteristic.value.copyOf())
    }
    private fun receive(value: BluetoothGatt, bytes: ByteArray) {
        handler.post {
            if (!current(value) || bytes.isEmpty()) return@post
            when {
                stage == 1 && RecoveryProtocol.selfInfo(bytes) -> { stage = 2; write(value, RecoveryProtocol.deviceQuery()) }
                stage == 2 && RecoveryProtocol.deviceInfo(bytes) -> {
                    stage = 3; handler.removeCallbacks(deadline)
                    status("Recovered radio monitoring. Open MeshScout for messages and controls.")
                }
                stage == 3 && RecoveryProtocol.waiting(bytes) -> alert()
            }
        }
    }
    private fun alert() {
        if (alerted || !context.getSharedPreferences("message-alerts", Context.MODE_PRIVATE).getBoolean("enabled", false)) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return
        val intent = Intent(context, MainActivity::class.java).putExtra("open_messages", true).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(context, 43, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, "meshscout_messages") else Notification.Builder(context)
        manager.notify(43, builder.setSmallIcon(android.R.drawable.stat_notify_chat).setContentTitle("MeshScout messages waiting")
            .setContentText("Open MeshScout to retrieve your inbox.").setContentIntent(pending).setAutoCancel(true)
            .setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE).build())
        alerted = true
    }
}
