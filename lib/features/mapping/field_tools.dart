import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../offline/offline_maps.dart';
import 'mapping_notifier.dart';
import 'mapping_service.dart';

class CoverageSummary {
  CoverageSummary(MappingSession session) {
    count = session.observations.length;
    if (count > 0) {
      meanRssi =
          session.observations.fold<double>(0, (n, o) => n + o.rssi) / count;
      meanSnr =
          session.observations.fold<double>(0, (n, o) => n + o.snr) / count;
      strongest = session.observations.map((o) => o.rssi).reduce(math.max);
      weakest = session.observations.map((o) => o.rssi).reduce(math.min);
      for (final o in session.observations) {
        final key =
            '${(o.point.latitude * 1000).floor() / 1000}, ${(o.point.longitude * 1000).floor() / 1000}';
        cells.putIfAbsent(key, () => []).add(o.rssi);
      }
    }
    for (var i = 1; i < session.points.length; i++) {
      final a = session.points[i - 1], b = session.points[i];
      final lat = (b.latitude - a.latitude) * math.pi / 180,
          lon = (b.longitude - a.longitude) * math.pi / 180;
      final h =
          math.pow(math.sin(lat / 2), 2) +
          math.cos(a.latitude * math.pi / 180) *
              math.cos(b.latitude * math.pi / 180) *
              math.pow(math.sin(lon / 2), 2);
      distanceKm += 12742 * math.asin(math.sqrt(h.clamp(0, 1)));
    }
  }
  int count = 0;
  int? strongest, weakest;
  double? meanRssi, meanSnr;
  double distanceKm = 0;
  final Map<String, List<int>> cells = {};
}

MappingSession importRoute(String text) {
  if (utf8.encode(text).length > 20 * 1024 * 1024) {
    throw const FormatException('Route exceeds 20 MB.');
  }
  final data = jsonDecode(text) as Map<String, dynamic>;
  if (data.containsKey('crs')) {
    throw const FormatException(
      'Use WGS84 GeoJSON without a custom coordinate reference system.',
    );
  }
  Map<String, dynamic> geometry = data;
  if (data['type'] == 'Feature') {
    geometry = data['geometry'] as Map<String, dynamic>;
  }
  if (data['type'] == 'FeatureCollection') {
    final lines = (data['features'] as List)
        .where((f) => f['geometry']?['type'] == 'LineString')
        .toList();
    if (lines.length != 1) {
      throw const FormatException(
        'Choose a GeoJSON file with exactly one LineString route.',
      );
    }
    geometry = lines.single['geometry'] as Map<String, dynamic>;
  }
  if (geometry['type'] != 'LineString') {
    throw const FormatException('Use a GeoJSON LineString route.');
  }
  final coordinates = geometry['coordinates'] as List;
  if (coordinates.length < 2 || coordinates.length > 10000) {
    throw const FormatException('Use 2–10,000 route points.');
  }
  final now = DateTime.now().toUtc();
  final points = <GpsPoint>[];
  for (final row in coordinates) {
    if (row is! List || row.length < 2 || row[0] is! num || row[1] is! num) {
      throw const FormatException('Invalid route coordinate.');
    }
    final p = GpsPoint(
      (row[1] as num).toDouble(),
      (row[0] as num).toDouble(),
      0,
      now,
    );
    if (!p.valid) {
      throw const FormatException('Invalid WGS84 coordinates.');
    }
    points.add(p);
  }
  return MappingSession(
    id: 'import-${now.microsecondsSinceEpoch}',
    name: 'Imported planned route',
    planned: true,
    started: now,
    ended: now,
    points: points,
  );
}

final fieldNotesProvider =
    AsyncNotifierProvider<FieldNotes, List<Map<String, dynamic>>>(
      FieldNotes.new,
    );

class FieldNotes extends AsyncNotifier<List<Map<String, dynamic>>> {
  Future<File> file() async =>
      File('${await ref.read(dataDirectoryProvider)()}/field-notes.json');
  @override
  Future<List<Map<String, dynamic>>> build() async {
    final f = await file();
    return f.existsSync()
        ? (jsonDecode(await f.readAsString()) as List)
              .map((v) => Map<String, dynamic>.from(v as Map))
              .toList()
        : [];
  }

  Future<void> save(List<Map<String, dynamic>> notes) async {
    final f = await file(), tmp = await file();
    final pending = File('${tmp.path}.tmp');
    await pending.writeAsString(jsonEncode(notes), flush: true);
    await pending.rename(f.path);
    state = AsyncData(List.unmodifiable(notes));
  }

  Future<void> add(String name, String note, double lat, double lon) async {
    if (name.trim().isEmpty ||
        name.length > 80 ||
        note.length > 2000 ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      throw const FormatException(
        'Use a name up to 80 characters, note up to 2000 characters and valid coordinates.',
      );
    }
    final notes = state.requireValue;
    if (notes.length >= 1000) {
      throw const FormatException('Waypoint limit is 1,000.');
    }
    await save([
      ...notes,
      {
        'id': '${DateTime.now().microsecondsSinceEpoch}',
        'name': name.trim(),
        'note': note,
        'lat': lat,
        'lon': lon,
      },
    ]);
  }
}

class FieldToolsScreen extends ConsumerStatefulWidget {
  const FieldToolsScreen({super.key});
  @override
  ConsumerState<FieldToolsScreen> createState() => _FieldToolsState();
}

class _FieldToolsState extends ConsumerState<FieldToolsScreen> {
  String notice = '';
  String? first, second;
  bool busy = false;
  Future<void> action(Future<void> Function() task) async {
    if (busy) {
      return;
    }
    setState(() => busy = true);
    try {
      await task();
    } catch (e) {
      notice = 'Could not complete action: $e';
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mapping = ref.watch(mappingProvider),
        notes = ref.watch(fieldNotesProvider);
    Widget summary(MappingSession s) {
      final stats = CoverageSummary(s);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.name ?? s.id, style: Theme.of(context).textTheme.titleMedium),
          Text(
            '${stats.distanceKm.toStringAsFixed(2)} km route · ${stats.count} reception observations',
          ),
          if (stats.count > 0)
            Text(
              'RSSI mean ${stats.meanRssi!.toStringAsFixed(1)} dBm (${stats.weakest} to ${stats.strongest}) · mean SNR ${stats.meanSnr!.toStringAsFixed(1)} dB',
            ),
          for (final cell in stats.cells.entries.take(100))
            Row(
              children: [
                Expanded(child: Text(cell.key)),
                SizedBox(
                  width: 100,
                  child: LinearProgressIndicator(
                    value:
                        ((cell.value.reduce((a, b) => a + b) /
                                        cell.value.length +
                                    140) /
                                100)
                            .clamp(0, 1),
                  ),
                ),
                Text(' ${cell.value.length} samples'),
              ],
            ),
          const SizedBox(height: 16),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Coverage, waypoints & routes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (notice.isNotEmpty) Text(notice),
          const Text(
            'Compare completed sessions. Grid bars summarize measured RSSI within 0.001° cells (size varies with latitude). Empty cells have no evidence of coverage. Imported routes are planned geometry; accuracy and observation times are unknown.',
          ),
          for (final which in [0, 1])
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: which == 0 ? first : second,
              decoration: InputDecoration(labelText: 'Session ${which + 1}'),
              items: [
                for (final s in mapping.sessions)
                  DropdownMenuItem(
                    value: s.id,
                    child: Text(
                      s.name ?? s.id,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() {
                if (which == 0) {
                  first = v;
                } else {
                  second = v;
                }
              }),
            ),
          for (final s in mapping.sessions.where(
            (s) => s.id == first || s.id == second,
          ))
            summary(s),
          OutlinedButton(
            onPressed:
                busy ||
                    mapping.recording ||
                    mapping.busy ||
                    mapping.points.isNotEmpty
                ? null
                : () => action(() async {
                    final text = await const MethodChannel(
                      'org.meshscout/files',
                    ).invokeMethod<String>('openBackup');
                    if (text == null) {
                      return;
                    }
                    final route = importRoute(text);
                    await ref
                        .read(mappingProvider.notifier)
                        .importSession(route);
                    notice = 'Planned route imported into History.';
                  }),
            child: const Text('Import GeoJSON route'),
          ),
          FilledButton(
            onPressed: busy || !notes.hasValue
                ? null
                : () => action(() async {
                    final values = await showDialog<List<String>>(
                      context: context,
                      builder: (_) => const _WaypointDialog(),
                    );
                    if (values == null) {
                      return;
                    }
                    await ref
                        .read(fieldNotesProvider.notifier)
                        .add(
                          values[0],
                          values[1],
                          double.parse(values[2]),
                          double.parse(values[3]),
                        );
                    notice = 'Waypoint saved.';
                  }),
            child: const Text('Add waypoint and note'),
          ),
          if (notes.hasError)
            const Text('Waypoint storage could not be read. Restart to retry.'),
          for (final n in notes.value ?? <Map<String, dynamic>>[])
            ListTile(
              title: Text(n['name'] as String),
              subtitle: Text('${n['lat']}, ${n['lon']}\n${n['note']}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete waypoint',
                onPressed: busy
                    ? null
                    : () => action(() async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Delete waypoint?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (yes == true) {
                          await ref
                              .read(fieldNotesProvider.notifier)
                              .save(
                                notes.requireValue
                                    .where((v) => v['id'] != n['id'])
                                    .toList(),
                              );
                        }
                      }),
              ),
            ),
        ],
      ),
    );
  }
}

class _WaypointDialog extends StatefulWidget {
  const _WaypointDialog();
  @override
  State<_WaypointDialog> createState() => _WaypointState();
}

class _WaypointState extends State<_WaypointDialog> {
  final fields = List.generate(4, (_) => TextEditingController());
  @override
  void dispose() {
    for (final c in fields) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Waypoint'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++)
            TextField(
              controller: fields[i],
              decoration: InputDecoration(
                labelText: const ['Name', 'Note', 'Latitude', 'Longitude'][i],
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, fields.map((c) => c.text).toList()),
        child: const Text('Save'),
      ),
    ],
  );
}
