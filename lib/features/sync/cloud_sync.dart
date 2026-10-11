import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup/backup.dart';
import '../backup/preferences.dart';
import '../mapping/field_tools.dart';
import '../mapping/mapping_notifier.dart';
import '../messages/messages.dart';
import '../nodes/repeater_details.dart';
import '../offline/offline_maps.dart';
import '../radio/radio_notifier.dart';
import 'sync_engine.dart';

abstract class CloudSyncService {
  Future<dynamic> call(String method, [Map<String, dynamic>? args]);
}

class AndroidCloudSyncService implements CloudSyncService {
  static const files = MethodChannel('org.meshscout/files');
  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) =>
      files.invokeMethod<dynamic>(method, args);
}

class _UnavailableSync implements CloudSyncService {
  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) async =>
      {'enabled': false};
}

final cloudSyncServiceProvider =
    Provider<CloudSyncService>((ref) => _UnavailableSync());
final syncIntervalProvider =
    Provider<Duration>((ref) => const Duration(minutes: 1));
final cloudSyncProvider =
    NotifierProvider<CloudSync, CloudSyncState>(CloudSync.new);

class CloudSyncState {
  const CloudSyncState(
      {this.enabled = false,
      this.busy = false,
      this.folder = false,
      this.attention = false,
      this.notice = 'Automatic sync is off.'});
  final bool enabled, busy, folder, attention;
  final String notice;
}

class CloudSync extends Notifier<CloudSyncState> {
  Timer? _timer;
  bool _foreground = true;
  CloudSyncService get service => ref.read(cloudSyncServiceProvider);
  @override
  CloudSyncState build() {
    ref.onDispose(() => _timer?.cancel());
    return const CloudSyncState();
  }

  bool get available {
    final m = ref.read(mappingProvider), r = ref.read(radioProvider);
    return !state.busy &&
        !ref.read(maintenanceProvider) &&
        !m.loading &&
        !m.recording &&
        !m.busy &&
        m.points.isEmpty &&
        !ref.read(messagesProvider).busy &&
        !ref.read(messagesProvider.notifier).hasUnsaved &&
        !ref.read(offlineProvider).busy &&
        !ref.read(fieldNotesProvider).isLoading &&
        !ref.read(repeaterDetailsProvider).isLoading &&
        (r.phase == RadioPhase.idle || r.phase == RadioPhase.failed);
  }

  Future<void> initialize() async {
    try {
      final raw =
          Map<String, dynamic>.from(await service.call('syncStatus') as Map);
      if (!ref.mounted) return;
      state = CloudSyncState(
          enabled: raw['enabled'] == true,
          folder: raw['folder'] != null,
          notice: raw['enabled'] == true
              ? 'Automatic sync waits for the app to be open, idle and disconnected from the radio.'
              : 'Automatic sync is off.');
      _timer?.cancel();
      if (state.enabled)
        _timer = Timer.periodic(ref.read(syncIntervalProvider), (_) {
          if (_foreground && state.enabled && !state.attention && available)
            unawaited(run());
        });
    } catch (_) {
      if (ref.mounted)
        state =
            const CloudSyncState(notice: 'Sync settings could not be loaded.');
    }
  }

  void foreground(bool active) => _foreground = active;
  Future<void> chooseFolder() async {
    if (!available) return;
    final result = await service.call('syncFolder');
    if (result != null) await initialize();
  }

  Future<void> configure(bool enabled, {String password = ''}) async {
    if (!available) return;
    await service
        .call('syncConfigure', {'enabled': enabled, 'password': password});
    await initialize();
  }

  Future<void> run({Future<bool> Function(List<String>)? review}) async {
    if (!available || !state.enabled || !_foreground) return;
    final enabled = state.enabled, folder = state.folder;
    state = CloudSyncState(
        enabled: enabled,
        folder: folder,
        busy: true,
        notice: 'Syncing saved data…');
    final maintenance = ref.read(maintenanceProvider.notifier);
    maintenance.set(true);
    var attention = false;
    var notice = '';
    try {
      await ref.read(preferencesProvider.notifier).pending;
      final raw =
          Map<String, dynamic>.from(await service.call('syncLocal') as Map);
      final backup = ScoutBackup.decode(raw['data'] as String);
      final notes = (jsonDecode(raw['notes'] as String) as List).cast<Map<String, dynamic>>();
      final repeaters =
          (jsonDecode(raw['repeaters'] as String) as List).cast<Map<String, dynamic>>();
      final local = <String, Map<String, dynamic>>{
        for (final s in backup.sessions) 'session:${s.id}': s.toJson(),
        for (final m in backup.messages) 'message:${messageSyncId(m)}': m,
        for (final n in notes) 'note:${n['id']}': Map<String, dynamic>.from(n),
        for (final n in repeaters)
          'repeater:${n['key']}': Map<String, dynamic>.from(n),
      };
      final baselineText = raw['state'] as String;
      final baseline =
          baselineText == 'null' ? null : SyncSnapshot.decode(baselineText);
      final incoming = (await service.call('syncRead') as List)
          .cast<String>()
          .map(SyncSnapshot.decode)
          .toList();
      final merged = mergeSync(
          actor: raw['actor'] as String,
          sequence: raw['sequence'] as int,
          local: local,
          baseline: baseline,
          incoming: incoming);
      final conflicts = [
        for (final id in merged.conflicts)
          {
            'id': id,
            'previous': baseline?.records[id]?.value,
            'local': local[id],
            'proposed': merged.snapshot.records[id]?.value,
            'incoming': [
              for (final snapshot in incoming)
                if (snapshot.records.containsKey(id))
                  snapshot.records[id]!.toJson()
            ],
          }
      ];
      final conflictText = jsonEncode(conflicts);
      if (utf8.encode(conflictText).length > 4 * 1024 * 1024)
        throw const FormatException(
            'Conflict details exceed 4 MB; use manual backups to resolve.');
      final descriptions = [
        for (final id in merged.conflicts)
          '${id.split(':').first}: ${local[id]?['name'] ?? local[id]?['site'] ?? local[id]?['body'] ?? id.split(':').last}\nThis phone: ${_summary(local[id])}\nProposed: ${_summary(merged.snapshot.records[id]?.value)}'
      ];
      if (merged.conflicts.isNotEmpty &&
          (review == null || !await review(descriptions))) {
        attention = true;
        notice =
            'Conflicting edits found. Automatic sync paused; review the merge before applying.';
        return;
      }
      if (baseline != null &&
          canonical({
                for (final r in baseline.records.entries)
                  r.key: r.value.toJson()
              }) ==
              canonical({
                for (final r in merged.snapshot.records.entries)
                  r.key: r.value.toJson()
              })) {
        notice = 'Saved data is up to date.';
        return;
      }
      if (!_foreground) {
        notice = 'Sync deferred until the app is open again.';
        return;
      }
      final text = merged.snapshot.encode();
      // Publication must succeed before applying incoming changes locally.
      await service.call('syncPublish', {'snapshot': text});
      await service
          .call('syncApply', {'snapshot': text, 'conflicts': conflictText});
      ref.invalidate(mappingProvider);
      ref.invalidate(messagesProvider);
      ref.invalidate(fieldNotesProvider);
      ref.invalidate(repeaterDetailsProvider);
      ref.invalidate(offlineProvider);
      await ref.read(mappingProvider.notifier).initialize();
      await ref.read(messagesProvider.notifier).load();
      await ref.read(offlineProvider.notifier).initialize();
      notice =
          'Saved routes, messages, waypoints and repeater details synced. Deletions are retained. Last sync: ${DateTime.now().toLocal().toString().split('.').first}';
    } catch (_) {
      attention = true;
      notice =
          'Sync paused. Check folder access, passphrase, storage and data limits, then retry. Provider delays may postpone remote changes.';
    } finally {
      if (ref.mounted) maintenance.set(false);
      if (ref.mounted)
        state = CloudSyncState(
            enabled: enabled,
            folder: folder,
            attention: attention,
            notice: notice);
    }
  }
}

String _summary(Map<String, dynamic>? value) {
  if (value == null) return 'Deleted';
  final text = value.entries
      .where(
          (e) => !const ['id', 'key', 'points', 'observations'].contains(e.key))
      .map((e) => '${e.key}: ${e.value}')
      .join(' · ');
  return text.length > 4000 ? text.substring(0, 4000) : text;
}
