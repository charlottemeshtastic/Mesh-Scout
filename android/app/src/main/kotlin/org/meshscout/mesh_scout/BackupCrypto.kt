package org.meshscout.mesh_scout

import java.io.File
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Standard PBKDF2-HMAC-SHA256 + AES-256-GCM; authenticate fully before using plaintext. */
object BackupCrypto {
    private val magic = "MSCENC01".toByteArray(Charsets.US_ASCII)
    private fun key(password: String, salt: ByteArray): ByteArray {
        require(password.length >= 12) { "Use a passphrase of at least 12 characters" }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(password.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        var u = mac.doFinal(salt + byteArrayOf(0,0,0,1))
        val result = u.clone()
        repeat(149999) { u = mac.doFinal(u); for(i in result.indices) result[i] = (result[i].toInt() xor u[i].toInt()).toByte() }
        u.fill(0)
        return result
    }
    fun transform(input: File, output: File, password: String, encrypt: Boolean) {
        require(input.length() <= 550L * 1024 * 1024) { "Backup exceeds 550 MB" }
        val random = SecureRandom()
        try {
            DataInputStream(input.inputStream().buffered()).use { source ->
                DataOutputStream(output.outputStream().buffered()).use { target ->
                    val header = if(encrypt) magic + ByteArray(16).also(random::nextBytes) + ByteArray(12).also(random::nextBytes)
                        else ByteArray(36).also { source.readFully(it); require(it.copyOfRange(0,8).contentEquals(magic)) { "Invalid encrypted backup" } }
                    val derived = key(password, header.copyOfRange(8,24))
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(if(encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE, SecretKeySpec(derived,"AES"), GCMParameterSpec(128,header.copyOfRange(24,36)))
                    derived.fill(0)
                    cipher.updateAAD(header)
                    if(encrypt)target.write(header)
                    val buffer = ByteArray(65536)
                    while(true) { val count = source.read(buffer); if(count<0)break; cipher.update(buffer,0,count)?.let(target::write) }
                    target.write(cipher.doFinal()) // Wrong password/tampering/truncation fails here.
                    buffer.fill(0)
                }
            }
        } catch(e: Exception) { output.delete(); throw e }
    }
}
