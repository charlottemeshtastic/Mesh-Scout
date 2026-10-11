package org.meshscout.mesh_scout
import java.io.File
/** Remove unused restore profiles without deleting the active or referenced map profile. */
object ProfileCleanup {
    fun prune(root: File, current: File, maps: File) {
        val active = current.canonicalFile
        val referenced = maps.canonicalFile
        val base = root.canonicalPath
        fun inside(file: File, directory: String) = file.path == directory || file.path.startsWith(directory + File.separator)
        require(inside(active, base))
        require(inside(referenced, base))
        root.listFiles()?.filter { Regex("profile-[0-9]+").matches(it.name) }?.forEach { old ->
            val path = old.canonicalFile
            if (path != active && !inside(referenced, path.path)) {
                require(old.deleteRecursively()) { "Could not remove unused profile" }
            }
        }
    }
}
