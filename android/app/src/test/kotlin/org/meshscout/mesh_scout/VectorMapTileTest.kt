package org.meshscout.mesh_scout

import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream
import org.junit.Assert.*
import org.junit.Test

class VectorMapTileTest {
    private val tile = byteArrayOf(26, 9, 10, 5, 119, 97, 116, 101, 114, 120, 2)
    private fun rejects(bytes: ByteArray) {
        try { VectorMapTile.unpack(bytes); fail("Expected rejection") } catch (_: IllegalArgumentException) { }
    }
    @Test fun readsPlainAndGzipMvt() {
        assertEquals(setOf("water"), VectorMapTile.layers(tile))
        val output = ByteArrayOutputStream()
        GZIPOutputStream(output).use { it.write(tile) }
        assertArrayEquals(tile, VectorMapTile.unpack(output.toByteArray()))
    }
    @Test fun rejectsTruncatedInvalidWireAndVersion() {
        rejects(tile.copyOf(tile.size - 1))
        rejects(byteArrayOf(0))
        rejects(tile.copyOf().apply { this[lastIndex] = 3 })
        rejects(byteArrayOf(26, 127))
        rejects(ByteArray(0))
    }
    @Test fun boundsGzipExpansionBeforeParsing() {
        val output = ByteArrayOutputStream()
        GZIPOutputStream(output).use { it.write(ByteArray(VectorMapTile.MAX_BYTES + 1)) }
        rejects(output.toByteArray())
    }
}
