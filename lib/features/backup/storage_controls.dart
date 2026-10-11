import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../mapping/mapping_notifier.dart';
import '../messages/messages.dart';
import '../offline/offline_maps.dart';
import '../radio/radio_notifier.dart';
import 'backup.dart';

class StorageControls extends ConsumerStatefulWidget {
  const StorageControls({super.key});
  @override
  ConsumerState<StorageControls> createState() => _StorageControlsState();
}

class _StorageControlsState extends ConsumerState<StorageControls> {
  int? bytes;
  bool busy = false;
  String? notice;
  @override
  Widget build(BuildContext context) {
    final mapping = ref.watch(mappingProvider);
    final messages = ref.watch(messagesProvider);
    final offline = ref.watch(offlineProvider);
    final idle = !busy &&
        !mapping.loading &&
        !mapping.busy &&
        !mapping.recording &&
        mapping.points.isEmpty &&
        messages.loaded &&
        !messages.busy &&
        !ref.read(messagesProvider.notifier).hasUnsaved &&
        !offline.busy &&
        !ref.watch(radioProvider).busy &&
        !ref.watch(maintenanceProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Storage', style: Theme.of(context).textTheme.titleLarge),
      Text(
          '${messages.items.length}/1,000 messages · ${mapping.sessions.length}/1,000 sessions · ${offline.areas.length}/5 map areas'),
      Text(
          '${(offline.areas.fold<int>(0, (total, area) => total + area.bytes) / 1048576).toStringAsFixed(1)} MB of saved map tiles'),
      if (bytes != null)
        Text(
            '${(bytes! / 1048576).toStringAsFixed(1)} MB of app files and cache'),
      if (notice != null) Text(notice!),
      const Text(
          'Export or back up important data first. Disconnect the radio and stop recording before cleanup. Saved map areas can be deleted individually on Map.'),
      OutlinedButton(
          onPressed: busy ? null : () => run('storageUsage'),
          child: const Text('Refresh storage usage')),
      TextButton(
          onPressed: idle && messages.items.length > 200
              ? () => confirm('Keep only the latest 200 messages?',
                  ref.read(messagesProvider.notifier).pruneHistory)
              : null,
          child: const Text('Keep latest 200 messages')),
      TextButton(
          onPressed: idle && mapping.sessions.length > 20
              ? () => confirm('Keep only the latest 20 sessions?',
                  ref.read(mappingProvider.notifier).pruneHistory)
              : null,
          child: const Text('Keep latest 20 sessions')),
      TextButton(
          onPressed: idle
              ? () => confirm('Delete the paused map download?',
                  ref.read(offlineProvider.notifier).discardPending)
              : null,
          child: const Text('Remove paused download')),
      TextButton(
          onPressed: idle
              ? () => confirm('Remove unused restore profiles?',
                  () => run('cleanRetiredProfiles'))
              : null,
          child: const Text('Remove unused restore profiles')),
    ]);
  }

  Future<void> confirm(String title, Future<void> Function() action) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
                title: Text(title),
                content: const Text(
                    'This removes local data. Your current map files and exported backups are kept.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Remove'))
                ]));
    if (yes != true || !mounted) {
      return;
    }
    setState(() => busy = true);
    ref.read(maintenanceProvider.notifier).set(true);
    try {
      await action();
      if (mounted) {
        setState(() => notice = 'Cleanup completed.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => notice = 'Cleanup failed. Try again.');
      }
    } finally {
      if (mounted) {
        ref.read(maintenanceProvider.notifier).set(false);
        setState(() => busy = false);
      }
    }
  }

  Future<void> run(String method) async {
    try {
      final result = await const MethodChannel('org.meshscout/files')
          .invokeMethod<num>(method);
      if (mounted) {
        setState(() => bytes = result?.toInt());
      }
    } catch (_) {
      if (method == 'cleanRetiredProfiles') {
        rethrow;
      }
      if (mounted) {
        setState(() => notice = 'Storage operation failed.');
      }
    }
  }
}
