import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../common/mesh_data.dart';
import '../backup/backup.dart';
import '../offline/offline_maps.dart';
import '../radio/advanced_radio.dart';

const repeaterFields = {
  'site': ('Site / location description', 120),
  'hardware': ('Radio hardware', 80),
  'antenna': ('Antenna', 160),
  'power': ('Transmit power (include units)', 40),
  'preset': ('Frequency / preset description', 80),
  'notes': ('Notes', 2000),
};
Map<String, String> validateRepeaterDetails(Map<String, dynamic> value) {
  final key = value['key'];
  if (key is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(key) ||
      value.keys.any((k) => k != 'key' && !repeaterFields.containsKey(k))) {
    throw const FormatException('Invalid repeater identity.');
  }
  final result = <String, String>{'key': key};
  for (final field in repeaterFields.entries) {
    final text = value[field.key] ?? '';
    if (text is! String ||
        text.length > field.value.$2 ||
        text.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'))) {
      throw const FormatException('Invalid repeater information.');
    }
    result[field.key] = text;
  }
  return result;
}

final repeaterDetailsProvider =
    AsyncNotifierProvider<RepeaterDetails, List<Map<String, String>>>(
        RepeaterDetails.new);

class RepeaterDetails extends AsyncNotifier<List<Map<String, String>>> {
  Future<File> file() async =>
      File('${await ref.read(dataDirectoryProvider)()}/repeater-details.json');
  @override
  Future<List<Map<String, String>>> build() async {
    final f = await file();
    if (!await f.exists()) return [];
    if (await f.length() > 4 * 1024 * 1024)
      throw const FormatException('Repeater information exceeds limit.');
    final raw = jsonDecode(await f.readAsString()) as List;
    if (raw.length > 1000)
      throw const FormatException('Repeater information limit reached.');
    return raw
        .map(
            (v) => validateRepeaterDetails(Map<String, dynamic>.from(v as Map)))
        .toList();
  }

  Future<void> save(Map<String, dynamic> value) async {
    if (ref.read(maintenanceProvider)) throw StateError('Wait for sync or restore to finish.');
    if (state.isLoading || state.hasError)
      throw StateError('Wait for repeater information to load.');
    final row = validateRepeaterDetails(value);
    final previous = state;
    final rows = [
      ...state.requireValue.where((r) => r['key'] != row['key']),
      row
    ];
    if (rows.length > 1000 ||
        utf8.encode(jsonEncode(rows)).length > 4 * 1024 * 1024)
      throw const FormatException('Repeater information limit reached.');
    state = const AsyncLoading();
    try {
      final f = await file(), temp = File('${(await file()).path}.tmp');
      await temp.writeAsString(jsonEncode(rows), flush: true);
      await temp.rename(f.path);
      state = AsyncData(List.unmodifiable(rows));
    } catch (_) {
      state = previous;
      rethrow;
    }
  }
}

class RepeaterDetailsScreen extends ConsumerStatefulWidget {
  const RepeaterDetailsScreen({super.key, required this.contact});
  final MeshContact contact;
  @override
  ConsumerState<RepeaterDetailsScreen> createState() => _RepeaterDetailsState();
}

class _RepeaterDetailsState extends ConsumerState<RepeaterDetailsScreen> {
  final form = GlobalKey<FormState>();
  final controllers = {
    for (final field in repeaterFields.keys) field: TextEditingController()
  };
  bool loaded = false;
  String notice = '';
  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(repeaterDetailsProvider);
    final blocked = ref.watch(maintenanceProvider);
    if (!loaded && details.hasValue) {
      final match =
          details.requireValue.where((r) => r['key'] == widget.contact.key);
      if (match.isNotEmpty) {
        for (final field in controllers.keys) {
          controllers[field]!.text = match.first[field] ?? '';
        }
      }
      loaded = true;
    }
    final c = widget.contact;
    return Scaffold(
      appBar: AppBar(title: Text(c.name.isEmpty ? 'Repeater details' : c.name)),
      body: SafeArea(
          child: Form(
              key: form,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                const Text('Full public key'),
                SelectableText(c.key),
                Text(c.lastAdvert == null
                    ? 'No advertised timestamp'
                    : 'Advertised: ${c.lastAdvert!.toLocal()}'),
                Text(c.latitude == null
                    ? 'No advertised position'
                    : 'Advertised position: ${c.latitude}, ${c.longitude}'),
                const Text(
                    'Radio-stored advertisements do not prove current reachability. The information below is entered by you; it is not verified administrator information and does not change the radio.'),
                if (details.isLoading) const LinearProgressIndicator(),
                if (details.hasError)
                  const Text(
                      'Saved information could not be loaded. Retry before editing.'),
                for (final field in repeaterFields.entries)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: TextFormField(
                        controller: controllers[field.key],
                        enabled:
                            loaded && !details.isLoading && !details.hasError,
                        maxLines: field.key == 'notes' ? 4 : 1,
                        maxLength: field.value.$2,
                        decoration: InputDecoration(labelText: field.value.$1),
                        validator: (value) =>
                            (value ?? '').length > field.value.$2
                                ? 'Too long'
                                : null,
                      )),
                FilledButton(
                    onPressed: !blocked && loaded && !details.isLoading && !details.hasError
                        ? () async {
                            if (!form.currentState!.validate()) return;
                            try {
                              await ref
                                  .read(repeaterDetailsProvider.notifier)
                                  .save({
                                'key': c.key,
                                for (final field in controllers.entries)
                                  field.key: field.value.text.trim()
                              });
                              if (mounted)
                                setState(() => notice =
                                    'Saved on this phone. Included in full backup and enabled folder sync.');
                            } catch (_) {
                              if (mounted)
                                setState(() => notice =
                                    'Could not save repeater information.');
                            }
                          }
                        : null,
                    child: const Text('Save repeater information')),
                OutlinedButton(
                    onPressed: blocked ? null : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) =>
                                AdvancedRadioScreen(contactKey: c.key))),
                    child: const Text(
                        'Path, status, telemetry and radio controls')),
                if (notice.isNotEmpty) Text(notice),
              ]))),
    );
  }
}
