import 'preferences.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backup.dart';
import '../mapping/mapping_notifier.dart';
import '../mapping/field_tools.dart';
import '../messages/messages.dart';
import '../offline/offline_maps.dart';
import '../radio/radio_notifier.dart';

ScoutBackup mergeBackups(ScoutBackup current,ScoutBackup incoming) {
  final ids=current.sessions.map((s)=>s.id).toSet();
  final sessions=[...current.sessions,...incoming.sessions.where((s)=>ids.add(s.id))];
  String identity(Map<String,dynamic> m)=>jsonEncode([m['radio'],m['peer'],m['time'],m['outgoing'],m['body']]);
  final messages=[...current.messages];final seen=messages.map(identity).toSet();
  for(final m in incoming.messages){if(seen.add(identity(m)))messages.add(m);}
  return ScoutBackup.decode(ScoutBackup(sessions,messages).encode());
}
class FullBackupControls extends ConsumerStatefulWidget {
  const FullBackupControls({super.key});
  @override ConsumerState<FullBackupControls> createState()=>_FullBackupState();
}
class _FullBackupState extends ConsumerState<FullBackupControls> {
  static const files=MethodChannel('org.meshscout/files');
  bool maps=false,encrypted=true,busy=false,scheduled=false;String notice='';
  Map<String,dynamic> status={};
  Future<String?> password() => showDialog<String>(context:context,builder:(_)=>const _Passphrase());
  bool get available {
    final m=ref.read(mappingProvider),r=ref.read(radioProvider),messages=ref.read(messagesProvider);
    return !m.loading && !m.recording && !m.busy && m.points.isEmpty && !messages.busy && !ref.read(messagesProvider.notifier).hasUnsaved && !ref.read(offlineProvider).busy && (r.phase==RadioPhase.idle || r.phase==RadioPhase.failed);
  }
  Future<void> perform(String method) async {
    if(busy || !available)return;
    String secret='';
    if(encrypted || method=='openBundle' || method=='cloudRestore' || method=='scheduleBackup') {
      final value=await password();if(value==null)return;secret=value;
      if((method=='saveBundle' || method=='cloudBackup' || method=='scheduleBackup') && secret.length<12){setState(()=>notice='Use a passphrase of at least 12 characters.');return;}
    }
    if(!mounted)return;
    setState(()=>busy=true);ref.read(maintenanceProvider.notifier).set(true);
    try {
      final result=await files.invokeMethod<dynamic>(method,{'password':secret,'maps':maps,'enabled':true});secret='';
      if(result==null){notice='Cancelled.';return;}
      if(method=='openBundle' || method=='cloudRestore') {
        final preview=jsonDecode(result as String) as Map<String,dynamic>;
        final incoming=ScoutBackup.decode(preview['data'] as String);
        if(!mounted)return;
        final mode=await showDialog<String>(context:context,builder:(c)=>AlertDialog(title:const Text('Restore full backup'),content:Text('${incoming.sessions.length} routes · ${incoming.messages.length} messages · ${preview['waypoints']} waypoints · maps ${preview['maps']==true?"included":"not included"}.\nMerge keeps existing session/waypoint IDs and settings, adds new messages, and retains map areas (maximum five). Replace restores included history/settings/maps. Save a current backup first.'),actions:[TextButton(onPressed:()=>Navigator.pop(c),child:const Text('Cancel')),TextButton(onPressed:()=>Navigator.pop(c,'merge'),child:const Text('Merge')),FilledButton(onPressed:()=>Navigator.pop(c,'replace'),child:const Text('Replace'))]));
        if(mode==null)return;
        final data=mode=='merge'?mergeBackups(ScoutBackup.decode((await files.invokeMethod<String>('readBackup'))!),incoming):incoming;
        await files.invokeMethod<bool>('restoreBundle',{'data':data.encode(),'merge':mode=='merge'});
        ref.invalidate(mappingProvider);ref.invalidate(messagesProvider);ref.invalidate(fieldNotesProvider);ref.invalidate(offlineProvider);ref.invalidate(preferencesProvider);
        await ref.read(mappingProvider.notifier).initialize();await ref.read(messagesProvider.notifier).load();await ref.read(offlineProvider.notifier).initialize();await ref.read(preferencesProvider.notifier).initialize();
        notice='Backup restored. Restart MeshScout to apply restored preferences.';
      }else{notice=method=='scheduleBackup'?'Daily encrypted backups enabled while charging and online. Android and the document provider may delay writes.':'Completed.';}
      await refresh();
    }catch(_){notice='Operation failed. Check passphrase, available storage and document-provider access. Existing app data was retained unless restore already completed.';}
    finally{secret='';ref.read(maintenanceProvider.notifier).set(false);if(mounted)setState(()=>busy=false);}
  }
  Future<void> refresh()async{final raw=await files.invokeMapMethod<String,dynamic>('backupStatus');if(mounted){status=raw??{};scheduled=status['scheduled']==true;}}
  @override void initState(){super.initState();WidgetsBinding.instance.addPostFrameCallback((_)async{try{await refresh();if(mounted)setState((){});}catch(_){}});}
  @override Widget build(BuildContext context) {
    ref.watch(mappingProvider);ref.watch(messagesProvider);ref.watch(radioProvider);ref.watch(offlineProvider);
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      const Divider(),const Text('Full backup, merge and cloud document'),
      const Text('Includes history, waypoints, notes and reconnect and background-GPS preferences; optionally saved raster maps. Radio passwords, channel keys, provider permissions and in-progress recordings are excluded. Stop recording/downloads and disconnect first. Maximum 500 MB of maps and five map areas.'),
      SwitchListTile(title:const Text('Include offline maps'),value:maps,onChanged:busy?null:(v)=>setState(()=>maps=v)),
      SwitchListTile(title:const Text('Encrypt with passphrase'),subtitle:const Text('Keep the passphrase: it cannot be recovered. Restore can open an unencrypted backup with an empty passphrase.'),value:encrypted,onChanged:busy?null:(v)=>setState(()=>encrypted=v)),
      Wrap(children:[OutlinedButton(onPressed:available&&!busy?()=>perform('saveBundle'):null,child:const Text('Save full backup')),OutlinedButton(onPressed:available&&!busy?()=>perform('openBundle'):null,child:const Text('Open / merge / restore'))]),
      OutlinedButton(onPressed:available&&!busy?()=>perform('cloudTarget'):null,child:const Text('Choose dedicated backup document')),
      const Text('Choose a cloud provider in Android’s picker if available, or a local document. Upload overwrites that dedicated document; provider interruption may leave it incomplete. Keep a separate local backup. Cloud restore always previews changes; automatic two-way sync is not enabled.'),
      Wrap(children:[OutlinedButton(onPressed:available&&!busy&&status['target']!=null?()=>perform('cloudBackup'):null,child:const Text('Upload backup')),OutlinedButton(onPressed:available&&!busy&&status['target']!=null?()=>perform('cloudRestore'):null,child:const Text('Download / restore'))]),
      SwitchListTile(title:const Text('Daily encrypted backup'),subtitle:const Text('While charging and online; best effort. The passphrase is protected by Android Keystore on this phone. Overwrites the chosen document. Completed saved data only; GPS recording defers the job.'),value:scheduled,onChanged:!available||busy||status['target']==null?null:(v)async{if(v){await perform('scheduleBackup');}else{await files.invokeMethod<bool>('scheduleBackup',{'enabled':false});await refresh();if(mounted)setState((){});}}),
      if(status['status']!=null)Text(status['status'] as String),if(busy)const LinearProgressIndicator(),if(notice.isNotEmpty)Text(notice),
    ]);
  }
}
class _Passphrase extends StatefulWidget {
  const _Passphrase();@override State<_Passphrase> createState()=>_PassphraseState();
}
class _PassphraseState extends State<_Passphrase> {
  final text=TextEditingController();@override void dispose(){text.clear();text.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>AlertDialog(title:const Text('Backup passphrase'),content:TextField(controller:text,obscureText:true,autocorrect:false,enableSuggestions:false,decoration:const InputDecoration(labelText:'12+ characters to encrypt; empty for plain restore')),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(context,text.text),child:const Text('Continue'))]);
}
