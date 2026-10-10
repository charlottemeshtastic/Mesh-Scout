import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../offline/offline_maps.dart';
import '../radio/radio_notifier.dart';
import '../mapping/mapping_notifier.dart';

final preferencesProvider =
    NotifierProvider<ScoutPreferences, String?>(ScoutPreferences.new);

class ScoutPreferences extends Notifier<String?> {
  bool initialized = false;
  Future<void> pending = Future.value();
  @override
  String? build() {
    ref.listen(radioProvider.select((s) => s.autoReconnect), (_, __) => save());
    ref.listen(backgroundGpsProvider, (_, __) => save());
    return null;
  }

  Future<void> initialize() async {
    if (initialized) { return; }
    try {
      final file =
          File('${await ref.read(dataDirectoryProvider)()}/settings.json');
      if (file.existsSync()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (data['autoReconnect'] is bool) {
          await ref
              .read(radioProvider.notifier)
              .setAutoReconnect(data['autoReconnect'] as bool); }
        if (data['backgroundGps'] is bool)
          ref
              .read(backgroundGpsProvider.notifier)
              .set(data['backgroundGps'] as bool);
      }
      initialized = true;
      save();
    } catch (_) {
      if (ref.mounted) { state = 'Saved preferences could not be loaded.'; }
    }
  }

  void save() {
    if (!initialized) { return; }
    final text = jsonEncode({
      'version': 1,
      'autoReconnect': ref.read(radioProvider).autoReconnect,
      'backgroundGps': ref.read(backgroundGpsProvider)
    });
    pending = pending.then((_) async {
      if (!ref.mounted) { return; }
      try {
        final root = await ref.read(dataDirectoryProvider)();
        final temp = File('$root/settings.json.tmp');
        await temp.writeAsString(text, flush: true);
        await temp.rename('$root/settings.json');
        if (ref.mounted) { state = null; }
      } catch (_) {
        if (ref.mounted) { state = 'Preferences could not be saved.'; }
      }
    });
  }
}
