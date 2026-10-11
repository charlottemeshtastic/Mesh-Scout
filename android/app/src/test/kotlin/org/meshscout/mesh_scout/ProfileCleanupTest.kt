package org.meshscout.mesh_scout
import org.junit.Assert.*
import org.junit.Test
import java.io.File
class ProfileCleanupTest {
    @Test fun currentAndReferencedMapsSurviveCleanup() {
        val root=java.nio.file.Files.createTempDirectory("meshscout-profiles").toFile()
        try {
            val current=File(root,"profile-3").apply{mkdirs()}
            val maps=File(root,"profile-1/offline").apply{mkdirs()}
            val tile=File(maps,"saved.tile").apply{writeText("map")}
            val unused=File(root,"profile-2").apply{mkdirs()}
            File(unused,"messages.json").writeText("[]")
            val legacy=File(root,"offline").apply{mkdirs()}
            ProfileCleanup.prune(root,current,maps)
            assertTrue(current.exists());assertTrue(tile.exists());assertFalse(unused.exists());assertTrue(legacy.exists())
            ProfileCleanup.prune(root,current,legacy)
            assertFalse(File(root,"profile-1").exists());assertTrue(current.exists());assertTrue(legacy.exists())
        }finally{root.deleteRecursively()}
    }
}
