package org.meshscout.mesh_scout
import java.io.File
/** Remove unused restore profiles without deleting the active or referenced map profile. */
object ProfileCleanup {
    fun prune(root: File, current: File, maps: File) {
        val active = current.canonicalFile
        val referenced = maps.canonicalFile
        require(active.toPath().startsWith(root.canonicalFile.toPath()))
        require(referenced.toPath().startsWith(root.canonicalFile.toPath()))
        root.listFiles()?.filter { Regex("profile-[0-9]+").matches(it.name) }?.forEach { old ->
            val path = old.canonicalFile
            if (path != active && !referenced.toPath().startsWith(path.toPath())) {
                require(old.deleteRecursively()) { "Could not remove unused profile" }
            }
        }
    }
}
