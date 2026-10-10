import 'package:mesh_scout/features/radio/diagnostics.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/radio/advanced_radio.dart';
import 'package:mesh_scout/features/mapping/field_tools.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';
import 'package:mesh_scout/features/backup/backup.dart';
import 'package:mesh_scout/features/backup/full_backup.dart';

void main() {
  test('telemetry signed values and truncated frames', () {
    expect(telemetryDescription([1, 103, 255, 215]), contains('-4.1'));
    expect(() => telemetryDescription([1, 103, 255]), throwsFormatException);
    expect(
        pathDescription([0x8d, 0, 0, 0, 0, 0, 0, 0, 1, 42, 0]), contains('2a'));
    expect(() => pathDescription([0x8d, 0, 0, 0, 0, 0, 0, 0, 2, 42]),
        throwsFormatException);
  });
  test('contact editing preserves paths and flags', () {
    final original = List<int>.filled(148, 0)
      ..[34] = 7
      ..[35] = 2
      ..[36] = 42;
    final command =
        contactCommand('ab' * 32, 'Field node', 2, original: original);
    expect(command.length, 148);
    expect(command[34], 7);
    expect(command[36], 42);
    expect(() => contactCommand('bad', 'name', 1), throwsFormatException);
    expect(() => contactCommand('ab' * 32, 'x' * 32, 1), throwsFormatException);
  });
  test('channel key validation and firmware ranges', () {
    expect(channelCommand(0, 8, 'Field', '01' * 16).length, 50);
    expect(
        () => channelCommand(8, 8, 'Field', '01' * 16), throwsFormatException);
    expect(() => channelCommand(0, 8, 'Field', 'bad'), throwsFormatException);
    expect(parametersCommand(915, 125, 7, 5).length, 11);
    expect(
        () => parametersCommand(double.nan, 125, 7, 5), throwsFormatException);
    expect(() => parametersCommand(915, 125, 13, 5), throwsFormatException);
  });
  test(
      'route import rejects invalid coordinates and preserves planned geometry',
      () {
    final route = importRoute(jsonEncode({
      'type': 'LineString',
      'coordinates': [
        [-80, 35],
        [-80.01, 35.01]
      ]
    }));
    expect(route.points.length, 2);
    expect(route.observations, isEmpty);
    expect(
        () => importRoute('{"type":"LineString","coordinates":[[0,91],[1,0]]}'),
        throwsFormatException);
  });
  test('merge preserves current IDs and deduplicates messages', () {
    final now = DateTime.utc(2026);
    final route =
        MappingSession(id: '1', started: now, ended: now, points: const []);
    final m = {
      'radio': 'r',
      'peer': 'p',
      'time': 1,
      'body': 'hello',
      'outgoing': false,
      'status': 'received'
    };
    final merged =
        mergeBackups(ScoutBackup([route], [m]), ScoutBackup([route], [m]));
    expect(merged.sessions.length, 1);
    expect(merged.messages.length, 1);
  });
  test('empty coverage has no invented metrics', () {
    final now = DateTime.utc(2026);
    final stats = CoverageSummary(
        MappingSession(id: '1', started: now, ended: now, points: const []));
    expect(stats.meanRssi, isNull);
    expect(stats.cells, isEmpty);
  });
}
