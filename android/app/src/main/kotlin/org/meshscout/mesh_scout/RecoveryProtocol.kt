package org.meshscout.mesh_scout
/** Identification-only frames for restarted monitoring; no radio mutations or queue pops. */
object RecoveryProtocol {
    fun appStart() = byteArrayOf(1,0,0,0,0,0,0,0) + "MeshScout".toByteArray(Charsets.US_ASCII)
    fun deviceQuery() = byteArrayOf(22,3)
    fun selfInfo(bytes: ByteArray) = bytes.size >= 58 && bytes[0].toInt() == 5
    fun deviceInfo(bytes: ByteArray) = bytes.size >= 80 && bytes[0].toInt() == 13 && (bytes[1].toInt() and 255) >= 3
    fun waiting(bytes: ByteArray) = bytes.size == 1 && (bytes[0].toInt() and 255) == 0x83
}
