package org.meshscout.mesh_scout

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Each device publishes immutable encrypted snapshots; no shared file overwrite. */
class CloudFolderSync(private val activity: Activity) {
    private val prefs get() = activity.getSharedPreferences("sync-folder", Context.MODE_PRIVATE)
    private var pending: MethodChannel.Result? = null
    private fun actor(): String = prefs.getString("actor", null) ?: UUID.randomUUID().toString().replace("-", "").also {
        require(prefs.edit().putString("actor", it).commit())
    }
    private fun status(): Map<String, Any?> = mapOf("enabled" to prefs.getBoolean("enabled", false), "folder" to prefs.getString("uri", null))
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (!call.method.startsWith("sync")) return false
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        if (call.method == "syncFolder") {
            require(pending == null); pending = result
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }, 807)
            return true
        }
        if (call.method == "syncStatus") { result.success(status()); return true }
        Thread {
            try {
                val value: Any? = synchronized(ScoutBundles.lock) {
                    when (call.method) {
                        "syncConfigure" -> {
                            val enabled = args["enabled"] == true
                            if (enabled) {
                                require(prefs.getString("uri", null) != null)
                                val password = args["password"] as? String ?: ""
                                require(password.length >= 12)
                                BackupJob.storePassword(activity, password, "sync-folder")
                            } else { prefs.edit().remove("secret").remove("iv").commit() }
                            require(prefs.edit().putBoolean("enabled", enabled).commit()); status()
                        }
                        "syncConflicts" -> File(ScoutStorage.directory(activity), "sync-conflicts.json").let { if(it.exists())it.readText() else "[]" }
                        "syncLocal" -> {
                            require(!GpsRecordingService.running)
                            val root = ScoutStorage.directory(activity)
                            fun read(name: String, fallback: String) = File(root, name).let { if (it.exists()) it.readText() else fallback }
                            mapOf("actor" to actor(), "sequence" to prefs.getLong("sequence", 0) + 1,
                                "data" to ScoutStorage.readBackup(activity), "notes" to read("field-notes.json", "[]"),
                                "repeaters" to read("repeater-details.json", "[]"),
                                "state" to if (read("sync-scope", "") == prefs.getString("uri", null)) read("sync-state.json", "null") else "null")
                        }
                        "syncRead" -> readFolder()
                        "syncPublish" -> publish(args["snapshot"] as String)
                        "syncApply" -> {
                            require(!GpsRecordingService.running)
                            val snapshot = JSONObject(args["snapshot"] as String)
                            val stage = File(activity.cacheDir, "sync-${System.nanoTime()}").apply { mkdirs() }
                            try {
                                val sessions = JSONArray(); val messages = JSONArray(); val notes = JSONArray(); val repeaters = JSONArray()
                                val records = snapshot.getJSONArray("records")
                                for (i in 0 until records.length()) {
                                    val r = records.getJSONObject(i); if (r.isNull("value")) continue
                                    val value = r.getJSONObject("value")
                                    when (r.getString("id").substringBefore(':')) {
                                        "session" -> sessions.put(value); "message" -> messages.put(value)
                                        "note" -> notes.put(value); "repeater" -> repeaters.put(value)
                                    }
                                }
                                ScoutStorage.write(File(stage, "manifest.json"), JSONObject().put("maps", false).toString())
                                ScoutStorage.write(File(stage, "field-notes.json"), notes.toString())
                                ScoutStorage.write(File(stage, "repeater-details.json"), repeaters.toString())
                                val conflicts=args["conflicts"] as? String?:"[]";require(conflicts.toByteArray().size<=4*1024*1024);JSONArray(conflicts)
                                if(conflicts!="[]")ScoutStorage.write(File(stage,"sync-conflicts.json"),conflicts)
                                ScoutStorage.write(File(stage, "sync-state.json"), snapshot.toString())
                                ScoutStorage.write(File(stage, "sync-scope"), prefs.getString("uri", null)!!)
                                val data = JSONObject().put("format", "meshscout-backup").put("version", 1).put("sessions", sessions).put("messages", messages)
                                ScoutBundles.restore(activity, stage, data.toString(), false)
                                true
                            } finally { stage.deleteRecursively() }
                        }
                        else -> throw IllegalArgumentException("Unknown sync operation")
                    }
                }
                activity.runOnUiThread { result.success(value) }
            } catch (e: Exception) { activity.runOnUiThread { result.error("sync", "Sync failed; check folder access and passphrase. Local history retained unless apply completed.", null) } }
        }.start()
        return true
    }
    fun activityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != 807) return false
        val result = pending ?: return true; pending = null
        if (code != Activity.RESULT_OK || data?.data == null) { result.success(null); return true }
        try {
            val uri = data.data!!
            activity.contentResolver.takePersistableUriPermission(uri, data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
            require(prefs.edit().putString("uri", uri.toString()).putBoolean("enabled", false).remove("secret").remove("iv").commit())
            result.success(status())
        } catch (e: Exception) { result.error("sync", "This provider cannot grant folder access", null) }
        return true
    }
    private data class Document(val uri: Uri, val name: String, val actor: String, val sequence: Long)
    private fun documents(): List<Document> {
        val tree = Uri.parse(prefs.getString("uri", null) ?: error("Choose a sync folder"))
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val result = mutableListOf<Document>()
        activity.contentResolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)!!.use { cursor ->
            var entries = 0
            while (cursor.moveToNext()) {
                require(++entries <= 1000) { "Use a dedicated sync folder" }
                val name = cursor.getString(1); val entry = SyncDocumentNames.parse(name) ?: continue
                result.add(Document(DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0)), name, entry.actor, entry.sequence))
            }
        }
        require(result.groupBy { it.actor }.size <= 8) { "Sync supports eight devices" }
        return result
    }
    private fun readFolder(): List<String> {
        require(prefs.getBoolean("enabled", false))
        val rows = documents()
        val latestNames = SyncDocumentNames.latest(rows.map { SyncDocumentNames.Entry(it.name,it.actor,it.sequence) }).map{it.name}.toSet()
        val latest = rows.filter { it.name in latestNames }
        val password = BackupJob.readPassword(activity, "sync-folder")
        var total = 0L
        return latest.map { document ->
            val encrypted = File.createTempFile("sync-read-", ".bin", activity.cacheDir)
            val plain = File.createTempFile("sync-read-", ".json", activity.cacheDir)
            try {
                activity.contentResolver.openInputStream(document.uri)!!.use { input -> encrypted.outputStream().use { ScoutBundles.copyBounded(input, it, 22L * 1024 * 1024) } }
                total += encrypted.length(); require(total <= 80L * 1024 * 1024)
                BackupCrypto.transform(encrypted, plain, password, false)
                require(plain.length() <= 20L * 1024 * 1024)
                val text = plain.readText(); val snapshot = JSONObject(text)
                require(snapshot.getString("actor") == document.actor && snapshot.getLong("sequence") == document.sequence)
                text
            } finally { encrypted.delete(); plain.delete() }
        }
    }
    private fun publish(text: String): Boolean {
        require(prefs.getBoolean("enabled", false) && !GpsRecordingService.running)
        require(text.toByteArray().size <= 20 * 1024 * 1024)
        val snapshot = JSONObject(text); val own = actor(); val sequence = snapshot.getLong("sequence")
        require(snapshot.getString("actor") == own && sequence > prefs.getLong("sequence", 0))
        val tree = Uri.parse(prefs.getString("uri", null))
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val plain = File.createTempFile("sync-write-", ".json", activity.cacheDir)
        val encrypted = File.createTempFile("sync-write-", ".bin", activity.cacheDir)
        var pendingUri: Uri? = null
        try {
            ScoutStorage.write(plain, text)
            BackupCrypto.transform(plain, encrypted, BackupJob.readPassword(activity, "sync-folder"), true)
            require(prefs.edit().putLong("sequence", sequence).commit())
            pendingUri = DocumentsContract.createDocument(activity.contentResolver, parent, "application/octet-stream", "meshscout-$own-$sequence.pending") ?: error("Create failed")
            activity.contentResolver.openOutputStream(pendingUri, "wt")!!.use { output -> encrypted.inputStream().use { it.copyTo(output) } }
            // Only a completely written document is renamed into the visible set.
            require(DocumentsContract.renameDocument(activity.contentResolver, pendingUri, "meshscout-$own-$sequence.mssync") != null)
            pendingUri = null
            // Keep the prior successful snapshot too. Never delete another actor's file.
            runCatching { documents().filter { it.actor == own }.sortedByDescending { it.sequence }.drop(2).forEach { DocumentsContract.deleteDocument(activity.contentResolver, it.uri) } }
            return true
        } finally {
            pendingUri?.let { runCatching { DocumentsContract.deleteDocument(activity.contentResolver, it) } }
            plain.delete(); encrypted.delete()
        }
    }
    fun dispose() { pending?.error("closed", "Sync picker interrupted", null); pending = null }
}
