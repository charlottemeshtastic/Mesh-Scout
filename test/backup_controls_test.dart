import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/backup/backup.dart';
import 'package:mesh_scout/features/radio/radio_controls.dart';

void main() {
  Map<String, dynamic> fixture() => {
        'format': 'meshscout-backup',
        'version': 1,
        'sessions': [
          {
            'id': 'a',
            'name': 'Trail',
            'started': '2026-10-10T10:00:00Z',
            'ended': '2026-10-10T10:01:00Z',
            'points': [
              {
                'lat': 35.2,
                'lon': -80.8,
                'accuracy': 5,
                'time': '2026-10-10T10:00:30Z'
              }
            ]
          }
        ],
        'messages': [
          {
            'body': 'hello 🌲',
            'peer': 'abc',
            'radio': 'radio',
            'status': 'Accepted by radio · delivery unconfirmed',
            'time': 1000,
            'outgoing': true,
            'tag': 42,
            'secret': 'excluded'
          }
        ]
      };
  test(
      'backup round trip retains history but excludes radio secrets and live ACK tags',
      () {
    final backup = ScoutBackup.decode(jsonEncode(fixture()));
    final decoded = ScoutBackup.decode(backup.encode());
    expect(decoded.sessions.single.name, 'Trail');
    expect(decoded.sessions.single.points.single.longitude, -80.8);
    expect(decoded.messages.single['body'], 'hello 🌲');
    expect(decoded.messages.single['status'], contains('unconfirmed'));
    expect(backup.encode(), isNot(contains('secret')));
    expect(decoded.messages.single.containsKey('tag'), isFalse);
  });
  test(
      'wrong format/version, malformed fields and duplicate routes are rejected',
      () {
    for (final value in [
      {'format': 'meshscout-message-history'},
      {...fixture(), 'version': 2},
      {
        ...fixture(),
        'messages': [
          {'body': 'invalid'}
        ]
      },
      {
        ...fixture(),
        'sessions': [...(fixture()['sessions'] as List), ...(fixture()['sessions'] as List)]
      }
    ]) {
      expect(
          () => ScoutBackup.decode(jsonEncode(value)), throwsFormatException);
    }
  });
  test(
      'invalid coordinates and reversed session time are rejected before restore',
      () {
    final json = fixture();
    json['sessions'][0]['points'][0]['lat'] = 100;
    expect(() => ScoutBackup.decode(jsonEncode(json)), throwsFormatException);
    final reversed = fixture();
    reversed['sessions'][0]['ended'] = '2026-10-09T10:00:00Z';
    expect(
        () => ScoutBackup.decode(jsonEncode(reversed)), throwsFormatException);
  });
  test('empty backup is valid and contains no synthetic history', () {
    final backup = ScoutBackup.decode(jsonEncode({
      'format': 'meshscout-backup',
      'version': 1,
      'sessions': [],
      'messages': []
    }));
    expect(backup.sessions, isEmpty);
    expect(backup.messages, isEmpty);
  });
  test('radio name and power commands reject truncation and invalid ranges',
      () {
    expect(radioNameCommand(' Trail 🌲 '), [8, ...utf8.encode('Trail 🌲')]);
    expect(() => radioNameCommand(List.filled(32, 'x').join()),
        throwsFormatException);
    expect(() => radioNameCommand('bad\nname'), throwsFormatException);
    expect(radioPowerCommand(-9, 22), [12, 247]);
    expect(() => radioPowerCommand(23, 22), throwsFormatException);
  });
  test(
      'status parses signed power and optional storage without exposing PIN/key bytes',
      () {
    final self = List<int>.filled(58, 0)
      ..[0] = 5
      ..[2] = 247
      ..[3] = 22;
    final device = List<int>.filled(80, 0)
      ..[0] = 13
      ..[4] = 99;
    final details = RadioDetails.parse(
        [...self, ...utf8.encode('Trail')], device, [12, 160, 15]);
    expect(details.name, 'Trail');
    expect(details.txPower, -9);
    expect(details.millivolts, 4000);
    expect(details.usedKb, isNull);
    expect(() => RadioDetails.parse([5], device, [12, 0, 0]),
        throwsFormatException);
  });
}
