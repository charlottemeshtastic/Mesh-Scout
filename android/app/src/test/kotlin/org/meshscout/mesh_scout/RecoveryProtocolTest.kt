package org.meshscout.mesh_scout
import org.junit.Assert.*
import org.junit.Test
class RecoveryProtocolTest {
    @Test fun identificationOnlyAndBoundedFrames() {
        assertArrayEquals(byteArrayOf(1,0,0,0,0,0,0,0) + "MeshScout".toByteArray(Charsets.US_ASCII), RecoveryProtocol.appStart())
        assertArrayEquals(byteArrayOf(22,3), RecoveryProtocol.deviceQuery())
        assertFalse(RecoveryProtocol.selfInfo(byteArrayOf()))
        assertFalse(RecoveryProtocol.selfInfo(ByteArray(57).also { it[0]=5 }))
        assertTrue(RecoveryProtocol.selfInfo(ByteArray(58).also { it[0]=5 }))
        assertFalse(RecoveryProtocol.deviceInfo(ByteArray(79).also { it[0]=13;it[1]=3 }))
        assertFalse(RecoveryProtocol.deviceInfo(ByteArray(80).also { it[0]=13;it[1]=2 }))
        assertTrue(RecoveryProtocol.deviceInfo(ByteArray(80).also { it[0]=13;it[1]=3 }))
        assertFalse(RecoveryProtocol.waiting(byteArrayOf()))
        assertFalse(RecoveryProtocol.waiting(byteArrayOf(0x83.toByte(),0)))
        assertTrue(RecoveryProtocol.waiting(byteArrayOf(0x83.toByte())))
    }
}
