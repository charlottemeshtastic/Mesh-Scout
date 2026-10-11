import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../common/mesh_data.dart';
import '../radio/radio_notifier.dart';
import '../settings/field_settings.dart';
import 'mapping_notifier.dart';
import 'mapping_service.dart';

/// Size of a saved-coverage cell in degrees (matches Coverage summaries).
const coverageCellDegrees = 0.001;

/// Most cells drawn at once; the newest are kept.
const maxCoverageCells = 5000;

/// One measured 0.001° cell across saved sessions.
class CoverageCell {
  const CoverageCell(
      {required this.row,
      required this.column,
      required this.bestRssi,
      required this.latest,
      required this.count});
  final int row, column, bestRssi, count;
  final DateTime latest;
  double get south => row * coverageCellDegrees;
  double get west => column * coverageCellDegrees;
  double get north => south + coverageCellDegrees;
  double get east => west + coverageCellDegrees;
}

/// Groups observations into cells keeping the strongest RSSI and newest time.
///
/// Sessions recorded on another preset are skipped when [preset] is given;
/// cells last measured before [since] are dropped when it is given.
List<CoverageCell> coverageCells(Iterable<MappingSession> sessions,
    {String? preset, DateTime? since}) {
  final cells = <(int, int), CoverageCell>{};
  for (final session in sessions) {
    if (session.planned) continue;
    if (preset != null && session.preset != preset) continue;
    for (final o in session.observations) {
      final row = (o.point.latitude / coverageCellDegrees).floor();
      final column = (o.point.longitude / coverageCellDegrees).floor();
      final previous = cells[(row, column)];
      cells[(row, column)] = CoverageCell(
          row: row,
          column: column,
          bestRssi: previous == null || o.rssi > previous.bestRssi
              ? o.rssi
              : previous.bestRssi,
          latest: previous == null || o.time.isAfter(previous.latest)
              ? o.time
              : previous.latest,
          count: (previous?.count ?? 0) + 1);
    }
  }
  final result = cells.values
      .where((c) => since == null || !c.latest.isBefore(since))
      .toList()
    ..sort((a, b) => b.latest.compareTo(a.latest));
  return result.length > maxCoverageCells
      ? result.sublist(0, maxCoverageCells)
      : result;
}

/// Saved coverage cells for the map, honouring the map settings.
final savedCoverageProvider = Provider<List<CoverageCell>>((ref) {
  final settings = ref.watch(fieldSettingsProvider);
  if (!settings.allCoverage) return const [];
  final sessions = ref.watch(mappingProvider.select((s) => s.sessions));
  final preset = settings.matchPreset
      ? ref.watch(radioProvider.select((s) => s.preset))?.key
      : null;
  final since = settings.recentCoverageOnly
      ? ref
          .read(mappingClockProvider)()
          .subtract(Duration(days: settings.recentCoverageDays))
      : null;
  return coverageCells(sessions, preset: preset, since: since);
});

/// Nodes advertised at (almost) the same spot, drawn as one marker.
class NodeGroup {
  const NodeGroup(this.nodes);
  final List<MeshContact> nodes;
  double get latitude => nodes.first.latitude!;
  double get longitude => nodes.first.longitude!;
}

/// Groups located nodes within about 11 m of each other. With [group] false
/// every node gets its own marker.
List<NodeGroup> groupNodes(Iterable<MeshContact> nodes, {bool group = true}) {
  final located =
      nodes.where((n) => n.latitude != null && n.longitude != null).toList();
  if (!group) return [for (final n in located) NodeGroup([n])];
  final groups = <(int, int), List<MeshContact>>{};
  for (final node in located) {
    final key = (
      (node.latitude! * 10000).round(),
      (node.longitude! * 10000).round()
    );
    groups.putIfAbsent(key, () => []).add(node);
  }
  return [for (final g in groups.values) NodeGroup(List.unmodifiable(g))];
}

/// Edge colour for a node marker by how recently it advertised.
Color advertColor(DateTime? lastAdvert, DateTime now) {
  if (lastAdvert == null) return Colors.blueGrey;
  final age = now.difference(lastAdvert);
  if (age <= const Duration(hours: 24)) return Colors.green;
  if (age <= const Duration(days: 7)) return Colors.amber;
  return Colors.blueGrey;
}

IconData nodeIcon(int type) => switch (type) {
      2 => Icons.cell_tower,
      3 => Icons.forum_outlined,
      4 => Icons.sensors,
      _ => Icons.person_outline,
    };

/// Neutral-bodied node marker with a coloured edge and optional count badge.
class NodeMarker extends StatelessWidget {
  const NodeMarker(
      {super.key, required this.group, required this.now, this.onTap});
  final NodeGroup group;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final newest = group.nodes
        .map((n) => n.lastAdvert)
        .whereType<DateTime>()
        .fold<DateTime?>(
            null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final single = group.nodes.length == 1;
    final first = group.nodes.first;
    final label = single
        ? '${first.name.isEmpty ? "Unnamed node" : first.name} · ${first.typeLabel} · advertised'
        : '${group.nodes.length} nodes at this location';
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Stack(clipBehavior: Clip.none, children: [
            Center(
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                    color: scheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: advertColor(newest, now), width: 3)),
                child: Icon(single ? nodeIcon(first.type) : Icons.layers,
                    size: 16, color: scheme.onSurface),
              ),
            ),
            if (!single)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text('${group.nodes.length}',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: scheme.onPrimary)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
