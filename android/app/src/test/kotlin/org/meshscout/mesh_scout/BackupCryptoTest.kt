package org.meshscout.mesh_scout
import org.junit.Assert.*
import org.junit.Test
import java.io.File
class BackupCryptoTest {
    @Test fun authenticatedStreamingBackup() {
        val root=java.nio.file.Files.createTempDirectory("meshscout-test").toFile()
        try {
            for(size in listOf(0,1,65536,180000)) {
                val original=File(root,"source").apply{writeBytes(ByteArray(size){(it%251).toByte()})}
                val encrypted=File(root,"encrypted");val decoded=File(root,"decoded")
                BackupCrypto.transform(original,encrypted,"test passphrase 2026",true)
                BackupCrypto.transform(encrypted,decoded,"test passphrase 2026",false)
                assertArrayEquals(original.readBytes(),decoded.readBytes())
                try { BackupCrypto.transform(encrypted,decoded,"wrong passphrase 2026",false);fail("Wrong password accepted") }catch(_:Exception){assertFalse(decoded.exists())}
                val valid=encrypted.readBytes()
                encrypted.writeBytes(valid.copyOf(valid.size-1))
                try { BackupCrypto.transform(encrypted,decoded,"test passphrase 2026",false);fail("Truncation accepted") }catch(_:Exception){assertFalse(decoded.exists())}
                valid[valid.size-1]=(valid.last().toInt() xor 1).toByte();encrypted.writeBytes(valid)
                try { BackupCrypto.transform(encrypted,decoded,"test passphrase 2026",false);fail("Tampering accepted") }catch(_:Exception){assertFalse(decoded.exists())}
            }
        }finally{root.deleteRecursively()}
    }
}
