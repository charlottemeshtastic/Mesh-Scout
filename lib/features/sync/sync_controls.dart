import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'cloud_sync.dart';
import '../mapping/mapping_notifier.dart';
import '../mapping/field_tools.dart';
import '../nodes/repeater_details.dart';
import '../messages/messages.dart';
import '../offline/offline_maps.dart';
import '../radio/radio_notifier.dart';
import '../backup/backup.dart';

class CloudSyncControls extends ConsumerStatefulWidget {
  const CloudSyncControls({super.key});
  @override
  ConsumerState<CloudSyncControls> createState() => _SyncControlsState();
}
class _SyncControlsState extends ConsumerState<CloudSyncControls> {
  String? error;
  Future<void> protect(Future<void> Function() action) async {
    try { await action(); if (mounted) setState(() => error = null); }
    catch (_) { if (mounted) setState(() => error = 'Could not change sync settings. Check provider access and passphrase.'); }
  }
  Future<void> enable(bool value) async {
    String password = '';
    if (value) {
      final text = TextEditingController();
      final answer = await showDialog<String>(context: context, builder: (c) => AlertDialog(
        title: const Text('Shared sync passphrase'),
        content: TextField(controller: text, obscureText: true, autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Same 12+ character passphrase on each device')),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, text.text), child: const Text('Enable'))],
      ));
      text.clear(); text.dispose();
      if (answer == null) return;
      if (answer.length < 12) { if (mounted) setState(() => error = 'Use at least 12 characters.'); return; }
      password = answer;
    }
    await protect(() => ref.read(cloudSyncProvider.notifier).configure(value, password: password));
  }
  @override
  Widget build(BuildContext context) {
    ref.watch(mappingProvider); ref.watch(messagesProvider); ref.watch(radioProvider);
    ref.watch(offlineProvider); ref.watch(fieldNotesProvider); ref.watch(repeaterDetailsProvider); ref.watch(maintenanceProvider);
    final state = ref.watch(cloudSyncProvider), actions = ref.read(cloudSyncProvider.notifier);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Divider(), const Text('Automatic two-way folder sync'),
      const Text('Saved routes, messages, waypoints and repeater notes. Choose the same dedicated shared folder and passphrase on each phone. Runs about once a minute while the app is open, idle and disconnected. Maps, radio keys, passwords and phone preferences stay local. Requires a provider supporting folder access; some cloud apps do not offer it.'),
      OutlinedButton(onPressed: actions.available ? () => protect(actions.chooseFolder) : null,
        child: const Text('Choose shared sync folder')),
      SwitchListTile(title: const Text('Automatic encrypted sync'), value: state.enabled,
        subtitle: const Text('Deleted records stay deleted. Concurrent edits pause automatic sync for review. Keep a separate full backup.'),
        onChanged: actions.available && state.folder ? enable : null),
      OutlinedButton(onPressed: actions.available && state.enabled ? () => protect(() => actions.run(review: (ids) async =>
        await showDialog<bool>(context: context, builder: (c) => AlertDialog(
          title: const Text('Review conflicting edits'),
          content: SingleChildScrollView(child: Text('${ids.length} records changed on multiple devices. Review the proposed values below. Alternative values are kept locally for export after applying.\n${ids.join('\n')}')),
          actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apply proposed merge'))],
        )) ?? false)) : null, child: Text(state.attention ? 'Review / retry sync' : 'Sync now')),
      OutlinedButton(onPressed: state.busy ? null : () => protect(() async {
        const files = MethodChannel('org.meshscout/files');
        final text = await ref.read(cloudSyncServiceProvider).call('syncConflicts') as String;
        await files.invokeMethod<bool>('save', {'name': 'MeshScout-sync-conflicts.json', 'mime': 'application/json', 'content': text});
      }), child: const Text('Export last conflict details')),
      if (state.busy) const LinearProgressIndicator(), Text(error ?? state.notice),
    ]);
  }
}
