package org.meshscout.mesh_scout

import android.app.Activity
import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.graphics.BitmapFactory
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream
import org.json.JSONArray
import org.json.JSONObject

/** App-private staging, bounded imports, and explicit document-provider access. */
class ScoutBundles(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    private var action = ""
    private var arguments: Map<String,Any?> = emptyMap()
    private var staged: File? = null
    fun dispose() { pending?.error("closed","File operation interrupted",null);pending=null;staged?.deleteRecursively();staged=null }
    private fun async(result: MethodChannel.Result, task: () -> Any?) {
        Thread { try { val value=task(); activity.runOnUiThread { result.success(value) } }
            catch(e:Exception) { activity.runOnUiThread { result.error("bundle",e.message,null) } } }.start()
    }
    fun handle(call: MethodCall,result: MethodChannel.Result): Boolean {
        if(call.method !in setOf("mapDirectory","importMap","saveBundle","openBundle","restoreBundle","cloudTarget","cloudBackup","cloudRestore","scheduleBackup","backupStatus"))return false
        try {
            val args=(call.arguments as? Map<String,Any?>)?:emptyMap()
            when(call.method) {
                "mapDirectory" -> result.success(ScoutStorage.mapDirectory(activity).absolutePath)
                "backupStatus" -> result.success(activity.getSharedPreferences("backup-job",Context.MODE_PRIVATE).let { mapOf("target" to it.getString("uri",null),"scheduled" to it.getBoolean("enabled",false),"status" to it.getString("status","No scheduled backup yet")) })
                "restoreBundle" -> async(result) {
                    require(!GpsRecordingService.running) { "Stop GPS recording first" }
                    val source=staged?:throw Exception("Open and preview a backup first")
                    val text=args["data"] as String
                    val merge=args["merge"]==true
                    synchronized(lock) { restore(activity,source,text,merge) }
                    source.deleteRecursively();staged=null;true
                }
                "cloudBackup" -> async(result) {
                    require(!GpsRecordingService.running)
                    val prefs=activity.getSharedPreferences("backup-job",Context.MODE_PRIVATE)
                    val uri=Uri.parse(prefs.getString("uri",null)?:throw Exception("Choose a dedicated backup document first"))
                    synchronized(lock) { val file=create(activity,args["password"] as? String?:"",args["maps"]==true);try { activity.contentResolver.openOutputStream(uri,"wt")!!.use { out->file.inputStream().use { it.copyTo(out) } } }finally{file.delete()} };true
                }
                "cloudRestore" -> async(result) {
                    val uri=Uri.parse(activity.getSharedPreferences("backup-job",Context.MODE_PRIVATE).getString("uri",null)?:throw Exception("Choose a backup document first"))
                    open(uri,args)
                }
                "scheduleBackup" -> {
                    val enabled=args["enabled"]==true
                    val prefs=activity.getSharedPreferences("backup-job",Context.MODE_PRIVATE)
                    val scheduler=activity.getSystemService(JobScheduler::class.java)
                    if(enabled) {
                        require(prefs.getString("uri",null)!=null) { "Choose a backup document first" }
                        val password=args["password"] as? String?:""
                        require(password.length>=12)
                        BackupJob.storePassword(activity,password)
                        val job=JobInfo.Builder(19030,ComponentName(activity,BackupJob::class.java)).setPeriodic(24*60*60*1000L).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setRequiresCharging(true).setPersisted(true).build()
                        require(scheduler.schedule(job)==JobScheduler.RESULT_SUCCESS)
                    }else { scheduler.cancel(19030);prefs.edit().remove("secret").remove("iv").apply() }
                    prefs.edit().putBoolean("enabled",enabled).putBoolean("maps",args["maps"]==true).apply();result.success(true)
                }
                else -> {
                    require(pending==null) { "A file picker is already open" }
                    pending=result; action=call.method;arguments=args
                    val intent=Intent(if(action=="saveBundle" || action=="cloudTarget")Intent.ACTION_CREATE_DOCUMENT else Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE);type="application/octet-stream"
                        if(action=="importMap" || action=="openBundle")type="*/*"
                        putExtra(Intent.EXTRA_TITLE,"MeshScout-${System.currentTimeMillis()}.msbackup")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                    }
                    activity.startActivityForResult(intent,806)
                }
            }
        }catch(e:Exception){if(pending===result)pending=null;result.error("bundle",e.message,null)}
        return true
    }
    fun activityResult(request:Int,code:Int,data:Intent?):Boolean {
        if(request!=806)return false
        val result=pending?:return true;pending=null
        if(code!=Activity.RESULT_OK || data?.data==null){result.success(null);return true}
        val uri=data.data!!;val args=arguments;val operation=action
        if(operation=="cloudTarget") {
            try { activity.contentResolver.takePersistableUriPermission(uri,data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION));activity.getSharedPreferences("backup-job",Context.MODE_PRIVATE).edit().putString("uri",uri.toString()).apply();result.success(true) }
            catch(e:Exception){result.error("provider",e.message,null)}
            return true
        }
        async(result) {
            when(operation) {
                "importMap" -> synchronized(lock) { importMap(uri) }
                "openBundle" -> open(uri,args)
                else -> synchronized(lock) {
                    val file=create(activity,args["password"] as? String?:"",args["maps"]==true)
                    try{activity.contentResolver.openOutputStream(uri,"wt")!!.use {out->file.inputStream().use{it.copyTo(out)}};true}finally{file.delete()}
                }
            }
        };return true
    }
    private fun open(uri:Uri,args:Map<String,Any?>):String {
        staged?.deleteRecursively();staged=null
        val copy=File.createTempFile("import-",".bin",activity.cacheDir)
        val plain=File.createTempFile("plain-",".zip",activity.cacheDir)
        val stage=File(activity.cacheDir,"bundle-${System.nanoTime()}").apply{mkdir()}
        try {
            activity.contentResolver.openInputStream(uri)!!.use{input->copy.outputStream().use{output->copyBounded(input,output,550L*1024*1024)}}
            val encrypted=copy.inputStream().use { it.readNBytesCompat(8).contentEquals("MSCENC02".toByteArray()) }
            if(encrypted)BackupCrypto.transform(copy,plain,args["password"] as? String?:"",false)
            val source=if(encrypted)plain else copy
            var bytes=0L;var count=0
            ZipInputStream(source.inputStream().buffered()).use { zip->
                while(true) {
                    val entry=zip.nextEntry?:break
                    require(++count<=50010 && !entry.isDirectory)
                    val name=entry.name
                    require(name in setOf("data.json","field-notes.json","settings.json","repeater-details.json","manifest.json") || Regex("offline/[a-zA-Z0-9-]+/(?:area\\.json|[0-9]+/[0-9]+/[0-9]+\\.tile)").matches(name)) { "Unexpected backup entry" }
                    val target=File(stage,name);require(!target.exists());target.parentFile!!.mkdirs()
                    target.outputStream().use{out->bytes+=copyBounded(zip,out,550L*1024*1024-bytes)}
                    if(!name.endsWith(".tile"))require(target.length()<=20L*1024*1024)
                }
            }
            val manifest=JSONObject(File(stage,"manifest.json").readText());require(manifest.getString("format")=="meshscout-bundle" && manifest.getInt("version")==2)
            validateExtras(stage)
            staged=stage
            return JSONObject().put("data",File(stage,"data.json").readText()).put("maps",manifest.getBoolean("maps")).put("waypoints",if(File(stage,"field-notes.json").exists())JSONArray(File(stage,"field-notes.json").readText()).length() else 0).put("encrypted",encrypted).toString()
        }catch(e:Exception){stage.deleteRecursively();throw e}finally{copy.delete();plain.delete()}
    }
    private fun importMap(uri:Uri):Boolean {
        val copy=File.createTempFile("map-",".mbtiles",activity.cacheDir)
        val root=ScoutStorage.mapDirectory(activity).apply{mkdirs()}
        require((root.listFiles()?.count{it.isDirectory && File(it,"area.json").exists()}?:0)<5) { "Delete an offline area first (limit five)" }
        val stage=File(root,"import-${System.nanoTime()}").apply{mkdir()}
        try {
            activity.contentResolver.openInputStream(uri)!!.use{input->copy.outputStream().use{out->copyBounded(input,out,500L*1024*1024)}}
            SQLiteDatabase.openDatabase(copy.path,null,SQLiteDatabase.OPEN_READONLY).use { db->
                val meta=mutableMapOf<String,String>();db.rawQuery("SELECT name,value FROM metadata",null).use{c->while(c.moveToNext())meta[c.getString(0)]=c.getString(1)}
                require(meta["format"] in listOf("png","jpg","jpeg","pbf")) { "Use PNG/JPEG or OpenMapTiles PBF MBTiles" }
                val vector=meta["format"]=="pbf";var supported=false
                db.rawQuery("SELECT count(*) FROM tiles WHERE length(tile_data) NOT BETWEEN 1 AND ${if(vector)VectorMapTile.MAX_BYTES else 1024*1024}",null).use{c->require(c.moveToFirst() && c.getInt(0)==0) { "Map pack contains oversized tiles" }}
                var count=0;var bytes=0L;var min=22;var max=0;var lat=0.0;var lon=0.0
                db.rawQuery("SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles",null).use{c->while(c.moveToNext()){
                    require(++count<=50000);val z=c.getInt(0);require(z in 0..22);val n=1 shl z;val x=c.getInt(1);val row=c.getInt(2);require(x in 0 until n && row in 0 until n)
                    val raw=c.getBlob(3)
                    val image=if(vector)VectorMapTile.unpack(raw) else raw
                    if(vector){if(VectorMapTile.layers(image).any{it in VectorMapTile.supportedLayers})supported=true}else validateImage(image)
                    bytes+=image.size;require(bytes<=500L*1024*1024)
                    val y=n-1-row;val target=File(stage,"$z/$x/$y.tile");require(!target.exists());target.parentFile!!.mkdirs();target.writeBytes(image)
                    min=kotlin.math.min(min,z);max=kotlin.math.max(max,z)
                    if(count==1){lon=(x+0.5)/n*360-180;lat=Math.toDegrees(kotlin.math.atan(kotlin.math.sinh(Math.PI*(1-2*(y+0.5)/n))))}
                }}
                require(count>0);require(!vector || supported) { "Map pack has no supported OpenMapTiles layers" }
                ScoutStorage.write(File(stage,"area.json"),JSONObject().put("lat",lat).put("lon",lon).put("tiles",count).put("bytes",bytes).put("sideKm",0).put("minZoom",min).put("maxZoom",max).put("name",(meta["name"]?:"Imported map").take(60)).put("kind",if(vector)"vector" else "raster").put("attribution",(meta["attribution"]?:"Imported map: see map pack license").replace(Regex("<[^>]*>"),"").take(1000)).toString())
            }
            require(stage.renameTo(File(root,"area-${System.nanoTime()}")));return true
        }catch(e:Exception){stage.deleteRecursively();throw e}finally{copy.delete()}
    }
    companion object {
        val lock=Any()
        private fun java.io.InputStream.readNBytesCompat(n:Int):ByteArray { val b=ByteArray(n);var i=0;while(i<n){val c=read(b,i,n-i);if(c<0)return b.copyOf(i);i+=c};return b }
        fun copyBounded(input:java.io.InputStream,out:java.io.OutputStream,limit:Long):Long {
            var total=0L;val buffer=ByteArray(65536);while(true){val n=input.read(buffer);if(n<0)break;total+=n;require(total<=limit){"File exceeds size limit"};out.write(buffer,0,n)};return total
        }
        fun create(context:Context,password:String,maps:Boolean):File {
            require(!GpsRecordingService.running) { "Stop recording before creating a full backup" }
            val plain=File.createTempFile("backup-",".zip",context.cacheDir)
            try {
                val root=ScoutStorage.directory(context)
                ZipOutputStream(plain.outputStream().buffered()).use{zip->
                    fun text(name:String,value:String){zip.putNextEntry(ZipEntry(name));zip.write(value.toByteArray());zip.closeEntry()}
                    text("manifest.json",JSONObject().put("format","meshscout-bundle").put("version",2).put("maps",maps).toString())
                    text("data.json",ScoutStorage.readBackup(context))
                    for(name in listOf("field-notes.json","settings.json","repeater-details.json")){val f=File(root,name);if(f.exists()){require(f.length()<=20L*1024*1024);text(name,f.readText())}}
                    if(maps){var bytes=0L;var count=0;val maproot=ScoutStorage.mapDirectory(context);if(maproot.exists())for(f in maproot.walkTopDown().filter{it.isFile && File(maproot,it.relativeTo(maproot).path.substringBefore('/')+"/area.json").exists()}){
                        val name="offline/"+f.relativeTo(maproot).invariantSeparatorsPath
                        if(!Regex("offline/[a-zA-Z0-9-]+/(?:area\\.json|[0-9]+/[0-9]+/[0-9]+\\.tile)").matches(name))continue
                        require(++count<=50000);bytes+=f.length();require(bytes<=500L*1024*1024);zip.putNextEntry(ZipEntry(name));f.inputStream().use{it.copyTo(zip)};zip.closeEntry()
                    }}
                }
                if(password.isEmpty())return plain
                val encrypted=File.createTempFile("backup-",".msbackup",context.cacheDir)
                BackupCrypto.transform(plain,encrypted,password,true);plain.delete();return encrypted
            }catch(e:Exception){plain.delete();throw e}
        }
        private fun validateImage(image:ByteArray) {
            require(image.size in 8..1024*1024)
            val options=BitmapFactory.Options().apply{inJustDecodeBounds=true}
            BitmapFactory.decodeByteArray(image,0,image.size,options)
            require(options.outWidth in 1..4096 && options.outHeight in 1..4096) { "Invalid or oversized raster tile" }
        }
        private fun validateExtras(stage:File) {
            val notes=File(stage,"field-notes.json")
            if(notes.exists()){val rows=JSONArray(notes.readText());require(rows.length()<=1000);for(i in 0 until rows.length()){val n=rows.getJSONObject(i);require(n.getString("id").length in 1..120 && n.getString("name").length in 1..80 && n.getString("note").length<=2000 && n.getDouble("lat").isFinite() && kotlin.math.abs(n.getDouble("lat"))<=90 && n.getDouble("lon").isFinite() && kotlin.math.abs(n.getDouble("lon"))<=180)}}
            val repeaters=File(stage,"repeater-details.json")
            if(repeaters.exists()){
                require(repeaters.length()<=4L*1024*1024);val rows=JSONArray(repeaters.readText());require(rows.length()<=1000)
                val limits=mapOf("key" to 64,"site" to 120,"hardware" to 80,"antenna" to 160,"power" to 40,"preset" to 80,"notes" to 2000)
                val seen=mutableSetOf<String>()
                for(i in 0 until rows.length()) { val row=rows.getJSONObject(i);val key=row.getString("key");require(Regex("[a-f0-9]{64}").matches(key) && seen.add(key));for(field in row.keys()){require(field in limits && row.get(field) is String && row.getString(field).length<=limits[field]!!)} }
            }
            val settings=File(stage,"settings.json");if(settings.exists()){require(settings.length()<10000);JSONObject(settings.readText())}
            val maps=File(stage,"offline");if(maps.exists()){val areas=maps.listFiles()?:emptyArray();require(areas.size<=5);for(a in areas){val m=JSONObject(File(a,"area.json").readText());require(m.getDouble("lat").isFinite() && kotlin.math.abs(m.getDouble("lat"))<=90 && m.getDouble("lon").isFinite() && kotlin.math.abs(m.getDouble("lon"))<=180);require(m.optInt("minZoom",12) in 0..22 && m.optInt("maxZoom",16) in m.optInt("minZoom",12)..22);require(m.optString("name").length<=60);val kind=m.optString("kind","raster");require(kind in listOf("raster","vector"));require(m.optString("attribution").length<=1000);for(f in a.walkTopDown().filter{it.extension=="tile"}){val parts=f.relativeTo(a).path.split('/');val z=parts[0].toInt();val x=parts[1].toInt();val y=parts[2].removeSuffix(".tile").toInt();require(z in 0..22 && x in 0 until (1 shl z) && y in 0 until (1 shl z) && f.length() in 1..VectorMapTile.MAX_BYTES.toLong());if(kind=="vector")VectorMapTile.layers(f.readBytes()) else validateImage(f.readBytes())}}}
        }
        fun restore(context:Context,source:File,text:String,merge:Boolean) {
            val old=ScoutStorage.directory(context);val oldmaps=ScoutStorage.mapDirectory(context)
            val target=File(context.filesDir,"profile-${System.nanoTime()}").apply{mkdir()}
            try {
                val data=JSONObject(text);require(data.getString("format")=="meshscout-backup" && data.getInt("version")==1)
                ScoutStorage.write(File(target,"mapping-sessions.json"),data.getJSONArray("sessions").toString());ScoutStorage.write(File(target,"messages.json"),data.getJSONArray("messages").toString())
                for(name in listOf("field-notes.json","settings.json","repeater-details.json","sync-state.json","sync-scope","sync-conflicts.json")) {
                    val incoming=File(source,name);val existing=File(old,name)
                    if(name in listOf("field-notes.json","repeater-details.json") && merge && incoming.exists()) {
                        val identity=if(name=="field-notes.json")"id" else "key";val rows=if(existing.exists())JSONArray(existing.readText())else JSONArray();val keys=(0 until rows.length()).map{rows.getJSONObject(it).getString(identity)}.toMutableSet();val added=JSONArray(incoming.readText());for(i in 0 until added.length()){val row=added.getJSONObject(i);if(keys.add(row.getString(identity)))rows.put(row)};require(rows.length()<=1000);if(name=="repeater-details.json")require(rows.toString().toByteArray().size<=4*1024*1024);ScoutStorage.write(File(target,name),rows.toString())
                    }else {val f=if(merge && existing.exists())existing else if(incoming.exists())incoming else existing;if(f.exists())f.copyTo(File(target,name))}
                }
                val imported=File(source,"offline")
                val includesMaps=JSONObject(File(source,"manifest.json").readText()).getBoolean("maps")
                if(includesMaps) {
                    val destination=File(target,"offline").apply{mkdir()}
                    if(merge && oldmaps.exists())oldmaps.listFiles()?.filter{File(it,"area.json").exists()}?.forEach{it.copyRecursively(File(destination,it.name))}
                    imported.listFiles()?.forEach{it.copyRecursively(File(destination,"area-${System.nanoTime()}"))};require((destination.listFiles()?.size?:0)<=5){"Merged backup would exceed five map areas"}
                }else ScoutStorage.write(File(target,"map-root"),oldmaps.relativeTo(context.filesDir).invariantSeparatorsPath)
                val pointer=File(context.filesDir,"data-pointer.tmp");ScoutStorage.write(pointer,target.name);require(pointer.renameTo(File(context.filesDir,"data-pointer")))
                GpsRecordingService.clearJournal(context)
            }catch(e:Exception){target.deleteRecursively();throw e}
            // Prior profiles remain recoverable and may own maps referenced by this profile.
        }
    }
}
