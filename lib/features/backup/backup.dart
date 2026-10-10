import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../mapping/mapping_service.dart';
import '../mapping/mapping_notifier.dart';
import '../messages/messages.dart';
import '../radio/radio_notifier.dart';

final maintenanceProvider = NotifierProvider<Maintenance, bool>(Maintenance.new);
class Maintenance extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

class ScoutBackup {
  const ScoutBackup(this.sessions, this.messages);
  final List<MappingSession> sessions;
  final List<Map<String, dynamic>> messages;
  String encode() => jsonEncode({'format': 'meshscout-backup', 'version': 1,
    'sessions': sessions.map((s) => s.toJson()).toList(), 'messages': messages});
  factory ScoutBackup.decode(String text) {
    if (utf8.encode(text).length > 20 * 1024 * 1024) throw const FormatException('Backup exceeds 20 MB.');
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic> || json['format'] != 'meshscout-backup' || json['version'] != 1 ||
        json['sessions'] is! List || json['messages'] is! List) throw const FormatException('Choose a MeshScout backup, version 1.');
    final sessions = decodeSessions(jsonEncode(json['sessions']));
    if (sessions.length > 1000 || sessions.map((s) => s.id).toSet().length != sessions.length) throw const FormatException('Invalid session count or duplicate IDs.');
    for (final s in sessions) {
      if (s.id.isEmpty || s.id.length > 120 || s.name != null && s.name!.length > 80 ||
          s.ended.isBefore(s.started) || s.points.length > 10000 || s.observations.length > 10000 ||
          s.points.any((p) => !p.valid) || s.observations.any((o) => !o.point.valid || !o.snr.isFinite || o.rssi < -200 || o.rssi > 100)) {
        throw const FormatException('Invalid route data.');
      }
    }
    final raw = json['messages'] as List;
    if (raw.length > 1000) throw const FormatException('Too many messages.');
    final messages = <Map<String, dynamic>>[];
    for (final m in raw) {
      if (m is! Map || m['body'] is! String || m['peer'] is! String || m['radio'] is! String ||
          m['status'] is! String || m['time'] is! int || m['outgoing'] is! bool ||
          (m['time'] as int) < 0 || (m['time'] as int) > 0xffffffff ||
          (m['body'] as String).length > 4096 || (m['peer'] as String).length > 200 ||
          (m['radio'] as String).length > 200 || (m['status'] as String).length > 200) throw const FormatException('Invalid message data.');
      messages.add({for (final key in ['body', 'peer', 'radio', 'status', 'time', 'outgoing']) key: m[key]});
    }
    return ScoutBackup(List.unmodifiable(sessions), List.unmodifiable(messages));
  }
}

class BackupControls extends ConsumerStatefulWidget {
  const BackupControls({super.key});
  @override
  ConsumerState<BackupControls> createState() => _BackupControlsState();
}
class _BackupControlsState extends ConsumerState<BackupControls> {
  static const channel = MethodChannel('org.meshscout/files');
  String? notice;
  bool get available {
    final mapping = ref.read(mappingProvider);
    final messages = ref.read(messagesProvider);
    final radio = ref.read(radioProvider);
    return !mapping.loading && !mapping.busy && !mapping.recording && mapping.points.isEmpty &&
        !messages.busy && !ref.read(messagesProvider.notifier).hasUnsaved && (radio.phase == RadioPhase.idle || radio.phase == RadioPhase.failed);
  }
  Future<void> perform(bool restore) async {
    if (!available || ref.read(maintenanceProvider)) return;
    ref.read(maintenanceProvider.notifier).set(true);
    try {
      if (restore) {
        final text = await channel.invokeMethod<String>('openBackup');
        if (text == null || !mounted) return;
        final backup = ScoutBackup.decode(text);
        final yes = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
          title: const Text('Replace routes and messages?'),
          content: Text('This backup contains ${backup.sessions.length} routes and ${backup.messages.length} messages. Restore replaces local route/message history. Offline maps and app settings stay on this phone. Save a backup first if you need the current history.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restore'))]));
        if (yes != true || !mounted) return;
        await channel.invokeMethod<void>('restoreBackup', backup.encode());
        ref.invalidate(mappingProvider);
        ref.invalidate(messagesProvider);
        await ref.read(mappingProvider.notifier).initialize();
        await ref.read(messagesProvider.notifier).load();
        notice = 'Routes and message history restored.';
      } else {
        final text = await channel.invokeMethod<String>('readBackup');
        final backup = ScoutBackup.decode(text!);
        final done = await channel.invokeMethod<bool>('save', {'name': 'MeshScout-Backup-${DateTime.now().millisecondsSinceEpoch}.json',
          'mime': 'application/json', 'content': backup.encode()});
        notice = done == true ? 'Backup saved.' : 'Backup cancelled.';
      }
    } catch (e) {
      notice = 'Backup/restore failed: $e';
    } finally {
      if (ref.mounted) ref.read(maintenanceProvider.notifier).set(false);
      if (mounted) setState(() {});
    }
  }
  @override
  Widget build(BuildContext context) {
    ref.watch(mappingProvider);
    ref.watch(messagesProvider);
    ref.watch(radioProvider);
    final busy = ref.watch(maintenanceProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Backup and restore'),
      const Text('Routes, session names, reception observations and message history. Up to 20 MB. Files contain precise locations and message text; keep them private. Maps, radio keys and app settings are not included. Stop recording and disconnect the radio first.'),
      Row(children: [Expanded(child: OutlinedButton(onPressed: available && !busy ? () => perform(false) : null, child: const Text('Save backup'))),
        Expanded(child: OutlinedButton(onPressed: available && !busy ? () => perform(true) : null, child: const Text('Restore backup')))]),
      if (busy) const LinearProgressIndicator(),
      if (notice != null) Text(notice!),
    ]);
  }
}
