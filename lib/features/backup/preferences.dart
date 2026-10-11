import 'dart:convert';
import 'dart:io';

import '../radio/ble_service.dart';
import '../../common/mesh_data.dart';
import '../messages/messages.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/offline_maps.dart';
import '../radio/radio_notifier.dart';
import '../mapping/mapping_notifier.dart';
import '../settings/field_settings.dart';

final preferencesProvider = NotifierProvider<ScoutPreferences, String?>(
  ScoutPreferences.new,
);

class ScoutPreferences extends Notifier<String?> {
  bool initialized = false;
  Future<void> pending = Future.value();
  @override
  String? build() {
    ref.listen(radioProvider.select((s) => s.autoReconnect), (_, __) => save());
    ref.listen(backgroundGpsProvider, (_, __) => save());
    ref.listen(autoInboxProvider, (_, __) => save());
    ref.listen(fieldSettingsProvider, (_, __) => save());
    ref.listen(radioProvider.select((s) => s.phase), (_, __) => save());
    ref.listen(radioProvider.select((s) => s.syncedAt), (_, __) => save());
    return null;
  }

  Future<void> initialize() async {
    if (initialized) {
      return;
    }
    try {
      final file = File(
        '${await ref.read(dataDirectoryProvider)()}/settings.json',
      );
      if (file.existsSync()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (data['autoReconnect'] is bool) {
          await ref
              .read(radioProvider.notifier)
              .setAutoReconnect(data['autoReconnect'] as bool);
        }
        if (data['autoInbox'] is bool) {
          ref.read(autoInboxProvider.notifier).set(data['autoInbox'] as bool);
        }
        final preferred = data['preferredRadio'];
        if (preferred is Map &&
            preferred['id'] is String &&
            preferred['name'] is String) {
          final cache = File(
            '${await ref.read(dataDirectoryProvider)()}/contacts-cache.json',
          );
          var contacts = <MeshContact>[];
          DateTime? synced;
          if (cache.existsSync()) {
            try {
              final saved = jsonDecode(
                await cache.readAsString(),
              ) as Map<String, dynamic>;
              if (saved['radio'] == preferred['id']) {
                final frames = saved['frames'] as List;
                if (frames.length > 5000) throw const FormatException();
                contacts = frames
                    .map((f) => MeshContact.parse(List<int>.from(f as List)))
                    .toList();
                synced = DateTime.parse(saved['synced'] as String);
              }
            } catch (_) {
              state = 'Contact cache could not be loaded; refresh from radio.';
            }
          }
          ref.read(radioProvider.notifier).restorePreferred(
                RadioDevice(
                  preferred['id'] as String,
                  preferred['name'] as String,
                  0,
                ),
                contacts,
                synced,
              );
        }
        if (data['field'] is Map) {
          ref.read(fieldSettingsProvider.notifier).set(
                FieldSettings.fromJson(
                  Map<String, dynamic>.from(data['field'] as Map),
                ),
              );
        }
        if (data['backgroundGps'] is bool) {
          ref
              .read(backgroundGpsProvider.notifier)
              .set(data['backgroundGps'] as bool);
        }
      }
      initialized = true;
      if (!ref.read(fieldSettingsProvider).guideSeen) {
        ref.read(firstRunGuideProvider.notifier).set(true);
      }
      final fileData = file.existsSync()
          ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
          : <String, dynamic>{};
      final shouldResume = fileData['resumeMonitoring'] == true &&
          ref.read(radioProvider).autoReconnect;
      if (shouldResume) {
        await ref.read(radioProvider.notifier).connectPreferred();
      }
      save();
    } catch (_) {
      if (ref.mounted) {
        state = 'Saved preferences could not be loaded.';
      }
    }
  }

  void save() {
    if (!initialized) {
      return;
    }
    final text = jsonEncode({
      'version': 1,
      'autoInbox': ref.read(autoInboxProvider),
      'resumeMonitoring': ref.read(radioProvider.notifier).resumeMonitoring,
      if (ref.read(radioProvider.notifier).preferred case final device?)
        'preferredRadio': {'id': device.id, 'name': device.name},
      'autoReconnect': ref.read(radioProvider).autoReconnect,
      'backgroundGps': ref.read(backgroundGpsProvider),
      'field': ref.read(fieldSettingsProvider).toJson(),
    });
    final radio = ref.read(radioProvider);
    final preferred = ref.read(radioProvider.notifier).preferred;
    final cache = radio.syncedAt == null || preferred == null
        ? null
        : jsonEncode({
            'radio': preferred.id,
            'synced': radio.syncedAt!.toUtc().toIso8601String(),
            'frames': radio.contacts.map((c) => c.frame).toList(),
          });
    pending = pending.then((_) async {
      if (!ref.mounted) {
        return;
      }
      try {
        final root = await ref.read(dataDirectoryProvider)();
        final temp = File('$root/settings.json.tmp');
        await temp.writeAsString(text, flush: true);
        await temp.rename('$root/settings.json');
        if (cache != null) {
          final tempCache = File('$root/contacts-cache.json.tmp');
          await tempCache.writeAsString(cache, flush: true);
          await tempCache.rename('$root/contacts-cache.json');
        }
        if (ref.mounted) {
          state = null;
        }
      } catch (_) {
        if (ref.mounted) {
          state = 'Preferences could not be saved.';
        }
      }
    });
  }
}
