import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/sync/sync_engine.dart';

void main() {
  final a = 'a' * 32, b = 'b' * 32;
  Map<String, dynamic> note(String text) =>
      {'id': 'n', 'name': 'Trail', 'note': text, 'lat': 35.0, 'lon': -80.0};
  SyncSnapshot snapshot(
          String actor, int revision, Map<String, dynamic>? value) =>
      SyncSnapshot(actor, revision,
          {'note:n': SyncRecord('note:n', revision, actor, value)});
  test('canonical identity ignores map order and message state changes', () {
    expect(canonical({'b': 2, 'a': 1}), canonical({'a': 1, 'b': 2}));
    final m = {
      'radio': 'r',
      'peer': 'p',
      'time': 1,
      'outgoing': false,
      'body': 'hi',
      'status': 'received'
    };
    expect(messageSyncId(m),
        messageSyncId({...m, 'status': 'read', 'unread': false}));
  });
  test('first sync merges records and roundtrips validated snapshots', () {
    final result = mergeSync(
        actor: a,
        sequence: 1,
        local: {'note:n': note('local')},
        baseline: null,
        incoming: []);
    expect(
        SyncSnapshot.decode(result.snapshot.encode())
            .records['note:n']!
            .value!['note'],
        'local');
    expect(result.conflicts, isEmpty);
  });
  test('deletion tombstones beat stale offline data without resurrection', () {
    final base = snapshot(a, 1, note('old'));
    final deleted = mergeSync(
        actor: a, sequence: 2, local: {}, baseline: base, incoming: [base]);
    expect(deleted.snapshot.records['note:n']!.value, isNull);
    final staleDevice = mergeSync(
        actor: b,
        sequence: 1,
        local: {'note:n': note('old')},
        baseline: base,
        incoming: [deleted.snapshot]);
    expect(staleDevice.snapshot.records['note:n']!.value, isNull);
    expect(staleDevice.conflicts, isEmpty);
  });
  test('concurrent edits are surfaced and logical revisions avoid clock skew',
      () {
    final base = snapshot(a, 1, note('old'));
    final result = mergeSync(
        actor: a,
        sequence: 2,
        local: {'note:n': note('local edit')},
        baseline: base,
        incoming: [snapshot(b, 3, note('remote edit'))]);
    expect(result.conflicts, ['note:n']);
    expect(result.snapshot.records['note:n']!.revision, 4);
    expect(result.snapshot.records['note:n']!.value!['note'], 'local edit');
  });
  test('equal remote revisions converge in either listing order', () {
    final one = snapshot(a, 1, note('one')), two = snapshot(b, 1, note('two'));
    SyncMerge merge(List<SyncSnapshot> rows) => mergeSync(
        actor: a, sequence: 2, local: {}, baseline: null, incoming: rows);
    expect(canonical(merge([one, two]).snapshot.records['note:n']!.toJson()),
        canonical(merge([two, one]).snapshot.records['note:n']!.toJson()));
    expect(merge([one, two]).snapshot.records['note:n']!.value!['note'], 'two');
  });
  test('same revision with different contents fails closed', () {
    expect(
        () => mergeSync(
            actor: a,
            sequence: 2,
            local: {},
            baseline: null,
            incoming: [
              snapshot(a, 1, note('one')),
              snapshot(a, 1, note('two'))
            ]),
        throwsFormatException);
  });
  test('malformed and nonportable data are rejected before publication', () {
    final encoded = jsonDecode(snapshot(a, 1, note('x')).encode()) as Map;
    encoded['records'][0]['value']['lat'] = 91;
    expect(
        () => SyncSnapshot.decode(jsonEncode(encoded)), throwsFormatException);
    expect(() => SyncSnapshot.decode(jsonEncode({...encoded, 'version': 2})),
        throwsFormatException);
    final m = {
      'radio': 'r',
      'peer': 'p',
      'time': 1,
      'outgoing': false,
      'body': 'hi',
      'status': 'received',
      'frame': [1, 2]
    };
    expect(
        () => validateSyncValues({
              'message:${messageSyncId(m)}':
                  SyncRecord('message:${messageSyncId(m)}', 1, a, m)
            }),
        throwsFormatException);
  });
  test('merged records do not restamp unchanged data', () {
    final base = snapshot(a, 7, note('same'));
    final result = mergeSync(
        actor: b,
        sequence: 2,
        local: {'note:n': note('same')},
        baseline: base,
        incoming: [base]);
    expect(result.snapshot.records['note:n']!.revision, 7);
    expect(result.conflicts, isEmpty);
  });
  test('large deletion history stays bounded and cannot be silently pruned',
      () {
    final rows = {
      for (var i = 0; i < 8000; i++)
        'note:$i': SyncRecord('note:$i', 1, a, null)
    };
    final snapshot = SyncSnapshot(a, 1, rows);
    final result = mergeSync(
        actor: b, sequence: 1, local: {}, baseline: null, incoming: [snapshot]);
    expect(result.snapshot.records.length, 8000);
    expect(
        () => mergeSync(
            actor: b,
            sequence: 2,
            local: {'note:n': note('new')},
            baseline: result.snapshot,
            incoming: []),
        throwsFormatException);
  });
}
