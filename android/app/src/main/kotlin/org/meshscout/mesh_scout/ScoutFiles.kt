package org.meshscout.mesh_scout

import android.app.Activity
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class ScoutFiles(private val activity: Activity) {
    private val bundles = ScoutBundles(activity)
    private var pending: MethodChannel.Result? = null
    private var content: String? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (bundles.handle(call, result)) return
        try {
            if (call.method == "directory") {
                result.success(activity.filesDir.absolutePath)
                return
            }
            if (call.method == "storageUsage" || call.method == "cleanRetiredProfiles") {
                Thread {
                    try {
                        val bytes = synchronized(ScoutBundles.lock) {
                            if (call.method == "cleanRetiredProfiles") {
                                require(!GpsRecordingService.running)
                                val current = ScoutStorage.directory(activity).canonicalFile
                                val maps = ScoutStorage.mapDirectory(activity).canonicalFile
                                activity.filesDir.listFiles()?.filter { Regex("profile-[0-9]+").matches(it.name) }?.forEach { old ->
                                    val path = old.canonicalFile
                                    if (path != current && !maps.toPath().startsWith(path.toPath())) {
                                        require(old.deleteRecursively()) { "Could not remove unused profile" }
                                    }
                                }
                            }
                            listOf(activity.filesDir, activity.cacheDir).sumOf { root -> root.walkTopDown().filter { it.isFile }.sumOf { it.length() } }
                        }
                        activity.runOnUiThread { result.success(bytes) }
                    } catch (e: Exception) { activity.runOnUiThread { result.error("storage", "Storage operation failed", null) } }
                }.start()
                return
            }
            if (call.method == "dataDirectory") { result.success(ScoutStorage.directory(activity).absolutePath); return }
            if (call.method == "readBackup" || call.method == "restoreBackup") {
                val restore = call.method == "restoreBackup"
                val text = if (restore) call.arguments as String else null
                Thread {
                    try {
                        val value = if (restore) {
                            require(!GpsRecordingService.running) { "Stop GPS recording first" }
                            ScoutStorage.restore(activity, text!!)
                            GpsRecordingService.clearJournal(activity)
                            null
                        } else ScoutStorage.readBackup(activity)
                        activity.runOnUiThread { result.success(value) }
                    } catch (e: Exception) { activity.runOnUiThread { result.error("backup", e.message, null) } }
                }.start()
                return
            }
            if (call.method == "openBackup") {
                require(pending == null)
                pending = result
                activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/json", "application/geo+json", "text/plain"))
                }, 805)
                return
            }
            if (call.method != "save" && call.method != "share") { result.notImplemented(); return }
            val name = call.argument<String>("name") ?: throw Exception("Missing name")
            val text = call.argument<String>("content") ?: throw Exception("Missing content")
            val mime = call.argument<String>("mime") ?: throw Exception("Missing type")
            require(Regex("MeshScout-(?:(?:Messages|Backup)-)?[0-9]+\\.(csv|geojson|json)").matches(name))
            require(text.toByteArray().size <= 20 * 1024 * 1024)
            if (call.method == "save") {
                if (pending != null) throw Exception("A save dialog is already open")
                pending = result
                content = text
                activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = mime
                    putExtra(Intent.EXTRA_TITLE, name)
                }, 804)
            } else {
                val directory = File(activity.cacheDir, "exports").apply { mkdirs() }
                // Keep at most 20 exports; avoid revoking a just-shared attachment.
                directory.listFiles()?.sortedBy { it.lastModified() }?.dropLast(19)?.forEach { it.delete() }
                val file = File(directory, name)
                file.writeText(text)
                val uri = FileProvider.getUriForFile(activity, activity.packageName + ".exports", file)
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uri)
                    clipData = android.content.ClipData.newRawUri("MeshScout export", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                activity.startActivity(Intent.createChooser(send, "Share MeshScout export"))
                result.success(true) // Chooser opened; delivery is controlled by the user/receiving app.
            }
        } catch (e: Exception) {
            if (pending === result) { pending = null; content = null }
            result.error("files", e.message, null)
        }
    }
    fun activityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (bundles.activityResult(request, code, data)) return true
        if (request == 805) {
            val result = pending ?: return true
            pending = null
            if (code != Activity.RESULT_OK || data?.data == null) { result.success(null); return true }
            val uri = data.data!!
            Thread {
                try {
                    val bytes = activity.contentResolver.openInputStream(uri)?.use { stream ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) { val n = stream.read(buffer); if (n < 0) break
                            require(output.size() + n <= 20 * 1024 * 1024) { "Backup exceeds 20 MB" }; output.write(buffer, 0, n) }
                        output.toByteArray()
                    } ?: throw Exception("Could not open backup")
                    val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    val text = decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
                    activity.runOnUiThread { result.success(text) }
                } catch (e: Exception) { activity.runOnUiThread { result.error("backup", e.message, null) } }
            }.start()
            return true
        }
        if (request != 804) return false
        val result = pending ?: return true
        val text = content
        pending = null
        content = null
        if (code != Activity.RESULT_OK || data?.data == null || text == null) {
            result.success(false)
            return true
        }
        val uri = data.data!!
        Thread {
            try {
                activity.contentResolver.openOutputStream(uri, "wt")?.use {
                    it.write(text.toByteArray(Charsets.UTF_8))
                } ?: throw Exception("Could not open destination")
                activity.runOnUiThread { result.success(true) }
            } catch (e: Exception) {
                activity.runOnUiThread { result.error("files", "Save failed: ${e.message}", null) }
            }
        }.start()
        return true
    }
    fun dispose() { bundles.dispose(); pending?.error("closed", "Save interrupted", null); pending = null; content = null }
}
