package org.meshscout.mesh_scout

import android.content.Context
import java.io.File
import org.json.JSONObject
import org.json.JSONArray

/** Publish both history files with one atomic directory-pointer replacement. */
object ScoutStorage {
    fun directory(context: Context): File {
        val pointer = File(context.filesDir, "data-pointer")
        if (!pointer.exists()) return context.filesDir
        val name = pointer.readText()
        require(Regex("profile-[0-9]+").matches(name))
        val directory = File(context.filesDir, name)
        require(directory.isDirectory)
        return directory
    }
    fun readBackup(context: Context): String {
        val root = directory(context)
        fun read(name: String) = File(root, name).let { if (it.exists()) JSONArray(it.readText()) else JSONArray() }
        val text = JSONObject().put("format", "meshscout-backup").put("version", 1)
            .put("sessions", read("mapping-sessions.json")).put("messages", read("messages.json")).toString()
        require(text.toByteArray().size <= 20 * 1024 * 1024) { "Backup exceeds 20 MB" }
        return text
    }
    fun restore(context: Context, text: String) {
        require(text.toByteArray().size <= 20 * 1024 * 1024)
        val backup = JSONObject(text)
        require(backup.getString("format") == "meshscout-backup" && backup.getInt("version") == 1)
        val previous = directory(context)
        val target = File(context.filesDir, "profile-${System.nanoTime()}")
        require(target.mkdir())
        try {
            write(File(target, "mapping-sessions.json"), backup.getJSONArray("sessions").toString())
            write(File(target, "messages.json"), backup.getJSONArray("messages").toString())
            val temp = File(context.filesDir, "data-pointer.tmp")
            write(temp, target.name)
            require(temp.renameTo(File(context.filesDir, "data-pointer")))
        } catch (e: Exception) { target.deleteRecursively(); throw e }
        // Cleanup never rolls back the already-published pair of history files.
        if (previous != context.filesDir) runCatching { previous.deleteRecursively() }
        else runCatching { File(previous, "mapping-sessions.json").delete(); File(previous, "messages.json").delete() }
    }
    fun write(file: File, text: String) {
        file.outputStream().use { stream -> stream.write(text.toByteArray(Charsets.UTF_8)); stream.fd.sync() }
    }
}
