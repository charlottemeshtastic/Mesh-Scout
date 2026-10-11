package org.meshscout.mesh_scout

import android.app.job.JobParameters
import android.app.job.JobService
import android.content.Context
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class BackupJob:JobService() {
    @Volatile private var stopped=false
    override fun onStartJob(params:JobParameters):Boolean {
        stopped=false
        Thread {
            val prefs=getSharedPreferences("backup-job",Context.MODE_PRIVATE)
            try {
                require(prefs.getBoolean("enabled",false) && !stopped && !GpsRecordingService.running)
                synchronized(ScoutBundles.lock) {
                    val cipher=Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,Base64.decode(prefs.getString("iv",null),Base64.NO_WRAP)))
                    val raw=cipher.doFinal(Base64.decode(prefs.getString("secret",null),Base64.NO_WRAP))
                    val file=try{ScoutBundles.create(this,raw.toString(Charsets.UTF_8),prefs.getBoolean("maps",false))}finally{raw.fill(0)}
                    try {
                        require(!stopped)
                        contentResolver.openOutputStream(Uri.parse(prefs.getString("uri",null)),"wt")!!.use{out->file.inputStream().use{it.copyTo(out)}}
                        prefs.edit().putString("status","Last backup completed: ${java.util.Date()}").apply()
                    }finally{file.delete()}
                }
            }catch(e:Exception){prefs.edit().putString("status","Backup deferred or failed; open MeshScout to retry.").apply()}
            jobFinished(params,false)
        }.start()
        return true
    }
    override fun onStopJob(params:JobParameters):Boolean { stopped=true;return true }
    companion object {
        private fun key():SecretKey {
            val store=KeyStore.getInstance("AndroidKeyStore").apply{load(null)}
            val existing=store.getKey("meshscout-backup",null) as? SecretKey
            if(existing!=null)return existing
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore").apply{init(KeyGenParameterSpec.Builder("meshscout-backup",KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())}.generateKey()
        }
        fun storePassword(context:Context,password:String,scope:String="backup-job") {
            val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key())
            val encrypted=cipher.doFinal(password.toByteArray(Charsets.UTF_8))
            context.getSharedPreferences(scope,Context.MODE_PRIVATE).edit().putString("secret",Base64.encodeToString(encrypted,Base64.NO_WRAP)).putString("iv",Base64.encodeToString(cipher.iv,Base64.NO_WRAP)).commit()
        }
        fun readPassword(context:Context,scope:String):String {
            val prefs=context.getSharedPreferences(scope,Context.MODE_PRIVATE)
            val cipher=Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE,key(),GCMParameterSpec(128,Base64.decode(prefs.getString("iv",null),Base64.NO_WRAP)))
            val raw=cipher.doFinal(Base64.decode(prefs.getString("secret",null),Base64.NO_WRAP))
            return try { raw.toString(Charsets.UTF_8) } finally { raw.fill(0) }
        }

    }
}
