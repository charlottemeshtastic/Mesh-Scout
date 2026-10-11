package org.meshscout.mesh_scout

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPInputStream

/** Bounded MVT framing validation, shared by import and backup restore. */
object VectorMapTile {
    const val MAX_BYTES = 4 * 1024 * 1024
    val supportedLayers = setOf("water", "waterway", "landuse", "landcover", "building", "transportation", "boundary", "place")
    fun unpack(bytes: ByteArray): ByteArray {
        require(bytes.size in 1..MAX_BYTES) { "Invalid vector tile size" }
        val decoded = if (bytes.size >= 2 && bytes[0] == 31.toByte() && bytes[1] == 139.toByte()) {
            GZIPInputStream(ByteArrayInputStream(bytes)).use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    require(output.size() + n <= MAX_BYTES) { "Expanded vector tile exceeds 4 MB" }
                    output.write(buffer, 0, n)
                }
                output.toByteArray()
            }
        } else bytes
        layers(decoded)
        return decoded
    }
    fun layers(bytes: ByteArray): Set<String> {
        require(bytes.size in 1..MAX_BYTES)
        val names = mutableSetOf<String>()
        val tile = Reader(bytes)
        var count = 0
        while (!tile.done) {
            val tag = tile.varint()
            if (tag == 26L) {
                require(++count <= 128) { "Too many vector layers" }
                val layer = Reader(tile.block())
                var name: String? = null
                var version = 1L
                while (!layer.done) {
                    val field = layer.varint()
                    when (field) {
                        10L -> { val raw = layer.block(); require(raw.size in 1..256); name = utf8(raw) }
                        18L -> validateFeature(layer.block())
                        26L -> { val raw=layer.block(); require(raw.size <= 65536); utf8(raw) }
                        34L -> validateValue(layer.block())
                        40L -> require(layer.varint() in 1..65536)
                        120L -> { version = layer.varint(); require(version in 1..2) }
                        else -> layer.skip(field)
                    }
                }
                require(name != null && version in 1..2) { "Invalid vector layer" }
                names.add(name)
            } else tile.skip(tag)
        }
        require(count > 0) { "No MVT layers found" }
        return names
    }
    private fun utf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
        .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
        .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
        .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    private fun validateFeature(bytes: ByteArray) {
        val reader = Reader(bytes)
        while (!reader.done) {
            val tag = reader.varint()
            when (tag) {
                18L, 34L -> {
                    val packed = Reader(reader.block())
                    var count = 0
                    while (!packed.done) { require(packed.varint() in 0..0xffffffffL); count++ }
                    if (tag == 18L) require(count % 2 == 0) { "Invalid feature tags" }
                }
                24L -> require(reader.varint() in 0..3)
                else -> reader.skip(tag)
            }
        }
    }
    private fun validateValue(bytes: ByteArray) {
        val reader = Reader(bytes)
        while (!reader.done) {
            val tag = reader.varint()
            if (tag == 10L) utf8(reader.block()) else reader.skip(tag)
        }
    }
    private class Reader(private val bytes: ByteArray) {
        private var offset = 0
        val done get() = offset == bytes.size
        fun varint(): Long {
            var value = 0L
            for (i in 0..9) {
                require(offset < bytes.size) { "Truncated vector tile" }
                val b = bytes[offset++].toInt() and 255
                if (i == 9) require(b <= 1)
                value = value or ((b and 127).toLong() shl (i * 7))
                if (b < 128) return value
            }
            error("Invalid vector varint")
        }
        fun block(): ByteArray {
            val length = varint()
            require(length in 0..(bytes.size - offset).toLong()) { "Invalid vector field length" }
            val result = bytes.copyOfRange(offset, offset + length.toInt())
            offset += length.toInt()
            return result
        }
        fun skip(tag: Long) {
            require(tag > 0 && tag ushr 3 > 0) { "Invalid vector field" }
            when ((tag and 7).toInt()) {
                0 -> varint()
                1 -> advance(8)
                2 -> { val n = varint(); require(n in 0..Int.MAX_VALUE.toLong()); advance(n.toInt()) }
                5 -> advance(4)
                else -> error("Unsupported vector wire type")
            }
        }
        private fun advance(n: Int) { require(n <= bytes.size - offset); offset += n }
    }
}
