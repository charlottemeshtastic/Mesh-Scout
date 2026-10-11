import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../backup/backup.dart';
import '../nodes/repeater_details.dart';

String canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(canonical).join(',')}]';
  return jsonEncode(value);
}

String messageSyncId(Map<String, dynamic> message) => sha256
    .convert(utf8.encode(canonical([
      message['radio'],
      message['peer'],
      message['time'],
      message['outgoing'],
      message['body'],
    ])))
    .toString();

/// Logical revisions avoid relying on phone clocks. Null values are permanent
/// deletion markers, so a disconnected device cannot resurrect old records.
class SyncRecord {
  const SyncRecord(this.id, this.revision, this.actor, this.value);
  final String id, actor;
  final int revision;
  final Map<String, dynamic>? value;
  Map<String, dynamic> toJson() => {
        'id': id,
        'revision': revision,
        'actor': actor,
        'value': value,
      };
  factory SyncRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'], revision = json['revision'], actor = json['actor'];
    if (id is! String ||
        id.length > 250 ||
        !RegExp(r'^(session|message|note|repeater):.+$').hasMatch(id) ||
        revision is! int ||
        revision < 1 ||
        revision > 9007199254740000 ||
        actor is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(actor) ||
        json['value'] != null && json['value'] is! Map) {
      throw const FormatException('Invalid sync record.');
    }
    return SyncRecord(
        id,
        revision,
        actor,
        json['value'] == null
            ? null
            : Map<String, dynamic>.from(json['value'] as Map));
  }
}

class SyncSnapshot {
  const SyncSnapshot(this.actor, this.sequence, this.records);
  final String actor;
  final int sequence;
  final Map<String, SyncRecord> records;
  String encode() => jsonEncode({
        'format': 'meshscout-sync',
        'version': 1,
        'actor': actor,
        'sequence': sequence,
        'records': records.values.map((r) => r.toJson()).toList(),
      });
  factory SyncSnapshot.decode(String text) {
    if (utf8.encode(text).length > 20 * 1024 * 1024) {
      throw const FormatException('Sync snapshot exceeds 20 MB.');
    }
    final data = jsonDecode(text);
    if (data is! Map ||
        data['format'] != 'meshscout-sync' ||
        data['version'] != 1 ||
        data['actor'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(data['actor'] as String) ||
        data['sequence'] is! int ||
        (data['sequence'] as int) < 0 ||
        (data['sequence'] as int) > 9007199254740000 ||
        data['records'] is! List ||
        (data['records'] as List).length > 8000) {
      throw const FormatException('Invalid sync snapshot.');
    }
    final records = <String, SyncRecord>{};
    for (final row in data['records'] as List) {
      final record = SyncRecord.fromJson(Map<String, dynamic>.from(row as Map));
      if (records.containsKey(record.id)) {
        throw const FormatException('Duplicate sync record.');
      }
      records[record.id] = record;
    }
    validateSyncValues(records);
    return SyncSnapshot(
        data['actor'] as String, data['sequence'] as int, records);
  }
}

/// Validates all payloads before any profile is published. Device preferences,
/// radio secrets, maps, native queue IDs and checkpoints never enter sync.
void validateSyncValues(Map<String, SyncRecord> records) {
  for (final r in records.values) {
    SyncRecord.fromJson(r.toJson());
  }
  final live = records.values.where((r) => r.value != null).toList();
  final sessions = [
    for (final r in live)
      if (r.id.startsWith('session:')) r.value
  ];
  final messages = [
    for (final r in live)
      if (r.id.startsWith('message:')) r.value
  ];
  final backup = ScoutBackup.decode(jsonEncode({
    'format': 'meshscout-backup',
    'version': 1,
    'sessions': sessions,
    'messages': messages,
  }));
  for (final session in backup.sessions) {
    if (canonical(records['session:${session.id}']?.value) !=
        canonical(session.toJson())) {
      throw const FormatException('Session identity mismatch.');
    }
  }
  for (final r in live.where((r) => r.id.startsWith('message:'))) {
    if (r.id != 'message:${messageSyncId(r.value!)}') {
      throw const FormatException('Message identity mismatch.');
    }
    if (r.value!.keys.any((k) => !const [
          'body',
          'peer',
          'radio',
          'status',
          'time',
          'outgoing',
          'unread'
        ].contains(k))) {
      throw const FormatException('Nonportable message fields.');
    }
  }
  final notes = live.where((r) => r.id.startsWith('note:')).toList();
  final repeaters = live.where((r) => r.id.startsWith('repeater:')).toList();
  if (notes.length > 1000 || repeaters.length > 1000) {
    throw const FormatException('Sync record limit reached.');
  }
  for (final r in notes) {
    final n = r.value!;
    if (r.id != 'note:${n['id']}' ||
        n['id'] is! String ||
        (n['id'] as String).length > 120 ||
        n['name'] is! String ||
        (n['name'] as String).length > 80 ||
        n['note'] is! String ||
        (n['note'] as String).length > 2000 ||
        n['lat'] is! num ||
        !(n['lat'] as num).isFinite ||
        (n['lat'] as num).abs() > 90 ||
        n['lon'] is! num ||
        !(n['lon'] as num).isFinite ||
        (n['lon'] as num).abs() > 180 ||
        n.keys.any(
            (k) => !const ['id', 'name', 'note', 'lat', 'lon'].contains(k))) {
      throw const FormatException('Invalid waypoint.');
    }
  }
  for (final r in repeaters) {
    final details = validateRepeaterDetails(r.value!);
    if (r.id != 'repeater:${details['key']}') {
      throw const FormatException('Repeater identity mismatch.');
    }
  }
}

class SyncMerge {
  const SyncMerge(this.snapshot, this.conflicts);
  final SyncSnapshot snapshot;
  final List<String> conflicts;
}

SyncMerge mergeSync({
  required String actor,
  required int sequence,
  required Map<String, Map<String, dynamic>> local,
  required SyncSnapshot? baseline,
  required List<SyncSnapshot> incoming,
}) {
  final result = <String, SyncRecord>{...?baseline?.records};
  var clock = 0;
  for (final snapshot in [if (baseline != null) baseline, ...incoming]) {
    for (final r in snapshot.records.values) {
      if (r.revision > clock) clock = r.revision;
    }
  }
  // Stamp against the last applied baseline before merging remote changes;
  // remote changes must not be mistaken for edits or deletions on this phone.
  for (final id in {...local.keys, ...?baseline?.records.keys}) {
    final value = local[id], old = baseline?.records[id];
    if (canonical(value) != canonical(old?.value)) {
      result[id] = SyncRecord(id, ++clock, actor, value);
    }
  }
  final conflicts = <String>[];
  for (final snapshot in incoming) {
    for (final entry in snapshot.records.entries) {
      final old = result[entry.key], next = entry.value;
      if (old == null) {
        result[entry.key] = next;
        continue;
      }
      if (old.revision == next.revision && old.actor == next.actor) {
        if (canonical(old.value) != canonical(next.value)) {
          throw const FormatException('Conflicting revision identity.');
        }
        continue;
      }
      final newer = next.revision > old.revision ||
          next.revision == old.revision && next.actor.compareTo(old.actor) > 0;
      if (canonical(old.value) != canonical(next.value) &&
          old.actor != next.actor &&
          canonical(baseline?.records[entry.key]?.value) !=
              canonical(old.value) &&
          canonical(baseline?.records[entry.key]?.value) !=
              canonical(next.value)) {
        conflicts.add(entry.key);
      }
      if (newer) result[entry.key] = next;
    }
  }
  if (result.length > 8000) {
    throw const FormatException('Sync is full; deletion history is retained.');
  }
  validateSyncValues(result);
  final snapshot = SyncSnapshot(actor, sequence, result);
  if (utf8.encode(snapshot.encode()).length > 20 * 1024 * 1024) {
    throw const FormatException('Merged sync exceeds 20 MB.');
  }
  final uniqueConflicts = conflicts.toSet().toList();
  if (uniqueConflicts.length > 50) {
    throw const FormatException('Too many conflicts; resolve with backups.');
  }
  return SyncMerge(snapshot, uniqueConflicts);
}
