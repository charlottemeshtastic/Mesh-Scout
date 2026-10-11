import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/common/mesh_data.dart';
import 'package:mesh_scout/features/alerts/link_alerts.dart';
import 'package:mesh_scout/features/export/session_export.dart';
import 'package:mesh_scout/features/mapping/map_layers.dart';
import 'package:mesh_scout/features/mapping/mapping_notifier.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';
import 'package:mesh_scout/features/mapping/trip_guard.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/settings/field_settings.dart';

import 'mapping_test.dart' show FakeMapping;

class RecordingLinkAlerts implements LinkAlertService {
  final calls = <String>[];
  @override
  Future<void> lost(String? name) async => calls.add('lost');
  @override
  Future<void> restored() async => calls.add('restored');
}

class PhaseRadio extends RadioNotifier {
  void move(RadioPhase phase) => state = state.copyWith(phase: phase);
}

Future<void> settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final base = DateTime.utc(2026, 10, 11, 12);

  group('trip guard', () {
    test(
      'altitude above 6,000 m or reported speed above 250 km/h is airborne',
      () {
        expect(
          isAirborne(GpsPoint(35, -80, 5, base, altitude: 6500), null),
          isTrue,
        );
        expect(
          isAirborne(GpsPoint(35, -80, 5, base, altitude: 1200), null),
          isFalse,
        );
        expect(isAirborne(GpsPoint(35, -80, 5, base, speed: 75), null), isTrue);
        expect(
          isAirborne(GpsPoint(35, -80, 5, base, speed: 30), null),
          isFalse,
        );
      },
    );

    test('derived speed needs fixes at least 10 s apart', () {
      final a = GpsPoint(35, -80, 5, base);
      // About 1.1 km in 1 s is a GPS jump, not a flight.
      final jump = GpsPoint(
        35.01,
        -80,
        5,
        base.add(const Duration(seconds: 1)),
      );
      expect(isAirborne(jump, a), isFalse);
      // About 11 km in 60 s is 667 km/h.
      final plane = GpsPoint(
        35.1,
        -80,
        5,
        base.add(const Duration(seconds: 60)),
      );
      expect(isAirborne(plane, a), isTrue);
    });

    test('parked tracker restarts when moving beyond the radius', () {
      final tracker = ParkedTracker(radiusMetres: 30);
      tracker.add(GpsPoint(35, -80, 5, base));
      tracker.add(
        GpsPoint(35.0001, -80, 5, base.add(const Duration(minutes: 5))),
      );
      expect(
        tracker.parked(
          base.add(const Duration(minutes: 10)),
          const Duration(minutes: 10),
        ),
        isTrue,
      );
      tracker.add(
        GpsPoint(35.001, -80, 5, base.add(const Duration(minutes: 11))),
      );
      expect(
        tracker.parked(
          base.add(const Duration(minutes: 12)),
          const Duration(minutes: 10),
        ),
        isFalse,
      );
    });
  });

  group('recording guards', () {
    late FakeMapping service;
    late ProviderContainer container;
    var offset = Duration.zero;

    setUp(() async {
      offset = Duration.zero;
      service = FakeMapping();
      container = ProviderContainer(
        overrides: [
          mappingServiceProvider.overrideWithValue(service),
          mappingClockProvider.overrideWithValue(
            () => DateTime.now().add(offset),
          ),
        ],
      );
      await container.read(mappingProvider.notifier).initialize();
    });
    tearDown(() async {
      container.dispose();
      await service.updates.close();
    });

    test('two airborne fixes stop recording and are not saved', () async {
      final actions = container.read(mappingProvider.notifier);
      await actions.start();
      final now = DateTime.now();
      service.updates.add(GpsPoint(35, -80, 5, now, altitude: 300));
      service.updates.add(
        GpsPoint(
          35,
          -80,
          5,
          now.add(const Duration(seconds: 5)),
          altitude: 9000,
        ),
      );
      expect(container.read(mappingProvider).recording, isTrue);
      service.updates.add(
        GpsPoint(
          35,
          -80,
          5,
          now.add(const Duration(seconds: 10)),
          altitude: 9100,
        ),
      );
      await settle();
      final state = container.read(mappingProvider);
      expect(state.recording, isFalse);
      expect(state.message, contains('flight'));
      final saved = decodeSessions(service.stored).single;
      expect(saved.points.single.altitude, 300);
    });

    test('flight check can be turned off', () async {
      container
          .read(fieldSettingsProvider.notifier)
          .update((s) => s.copyWith(aircraftGuard: false));
      final actions = container.read(mappingProvider.notifier);
      await actions.start();
      final now = DateTime.now();
      for (var i = 0; i < 3; i++) {
        service.updates.add(
          GpsPoint(35, -80, 5, now.add(Duration(seconds: i)), altitude: 9000),
        );
      }
      expect(container.read(mappingProvider).points.length, 3);
      await actions.stop();
    });

    test('staying within 30 m for the parked time stops and saves', () async {
      final actions = container.read(mappingProvider.notifier);
      await actions.start();
      final now = DateTime.now();
      service.updates.add(GpsPoint(35, -80, 5, now));
      offset = const Duration(minutes: 11);
      service.updates.add(GpsPoint(35.0001, -80, 5, now.add(offset)));
      await settle();
      final state = container.read(mappingProvider);
      expect(state.recording, isFalse);
      expect(state.message, contains('no movement for 10 min'));
      expect(decodeSessions(service.stored).single.points.length, 2);
    });

    test('parked auto-stop respects the setting', () async {
      container
          .read(fieldSettingsProvider.notifier)
          .update((s) => s.copyWith(autoStopParked: false));
      final actions = container.read(mappingProvider.notifier);
      await actions.start();
      final now = DateTime.now();
      service.updates.add(GpsPoint(35, -80, 5, now));
      offset = const Duration(minutes: 30);
      service.updates.add(GpsPoint(35.0001, -80, 5, now.add(offset)));
      await settle();
      expect(container.read(mappingProvider).recording, isTrue);
      await actions.stop();
    });
  });

  test('settings round-trip and reject invalid values', () {
    const custom = FieldSettings(
      autoStopParked: false,
      parkedMinutes: 30,
      recentCoverageOnly: true,
      recentCoverageDays: 7,
      guideSeen: true,
    );
    final restored = FieldSettings.fromJson(
      jsonDecode(jsonEncode(custom.toJson())) as Map<String, dynamic>,
    );
    expect(restored.toJson(), custom.toJson());
    final fallback = FieldSettings.fromJson({
      'parkedMinutes': 3,
      'recentCoverageDays': 'x',
      'guideSeen': 1,
    });
    expect(fallback.toJson(), const FieldSettings().toJson());
  });

  test('radio preset reads SELF_INFO and survives storage', () {
    final self = List<int>.filled(58, 0)..[0] = 5;
    void put(int offset, int value) {
      for (var i = 0; i < 4; i++) {
        self[offset + i] = (value >> (8 * i)) & 255;
      }
    }

    put(48, 910525);
    put(52, 62500);
    self[56] = 7;
    self[57] = 5;
    final preset = RadioPreset.fromSelfInfo(self)!;
    expect(preset.label, '910.525 MHz · 62.5 kHz · SF7 · CR5');
    expect(RadioPreset.parse(preset.key), preset);
    expect(RadioPreset.fromSelfInfo(List<int>.filled(58, 0)..[0] = 5), isNull);
    expect(RadioPreset.parse('garbage'), isNull);
    final session = MappingSession(
      id: '1',
      started: base,
      ended: base,
      points: const [],
      preset: preset.key,
    );
    expect(MappingSession.fromJson(session.toJson()).preset, preset.key);
  });

  test(
    'saved coverage keeps best RSSI per cell and filters age and preset',
    () {
      CoverageObservation rx(double lat, int rssi, DateTime time) =>
          CoverageObservation(
            point: GpsPoint(lat, -80, 5, time),
            rssi: rssi,
            snr: 1,
            time: time,
          );
      final old = base.subtract(const Duration(days: 60));
      final sessions = [
        MappingSession(
          id: 'a',
          started: base,
          ended: base,
          points: const [],
          preset: 'p1',
          observations: [rx(35.00001, -100, base), rx(35.00002, -85, base)],
        ),
        MappingSession(
          id: 'b',
          started: old,
          ended: old,
          points: const [],
          preset: 'p2',
          observations: [rx(35.01, -110, old)],
        ),
      ];
      final all = coverageCells(sessions);
      expect(all.length, 2);
      expect(all.first.bestRssi, -85);
      expect(all.first.count, 2);
      expect(
        coverageCells(
          sessions,
          since: base.subtract(const Duration(days: 30)),
        ).length,
        1,
      );
      expect(coverageCells(sessions, preset: 'p2').single.bestRssi, -110);
    },
  );

  test('nodes on one rooftop share a marker unless grouping is off', () {
    MeshContact node(String key, double lat) => MeshContact(
          key: key,
          name: key,
          type: 2,
          lastAdvert: null,
          latitude: lat,
          longitude: -80,
        );
    final nodes = [node('a', 35), node('b', 35.00001), node('c', 35.01)];
    final groups = groupNodes(nodes);
    expect(groups.length, 2);
    expect(
      groups.firstWhere((g) => g.nodes.length == 2).nodes.map((n) => n.key),
      ['a', 'b'],
    );
    expect(groupNodes(nodes, group: false).length, 3);
  });

  test('advert edge colour reflects how recently a node was heard', () {
    expect(
      advertColor(base.subtract(const Duration(hours: 2)), base).toARGB32(),
      isNot(advertColor(null, base).toARGB32()),
    );
  });

  group('link alerts', () {
    test('only a drop from ready alerts; reconnect clears it', () async {
      final alerts = RecordingLinkAlerts();
      final container = ProviderContainer(
        overrides: [
          linkAlertServiceProvider.overrideWithValue(alerts),
          radioProvider.overrideWith(PhaseRadio.new),
        ],
      );
      addTearDown(container.dispose);
      container.read(linkAlertsProvider);
      final radio = container.read(radioProvider.notifier) as PhaseRadio;
      radio.move(RadioPhase.connecting);
      radio.move(RadioPhase.ready);
      radio.move(RadioPhase.idle);
      await settle();
      expect(alerts.calls, isEmpty);
      radio.move(RadioPhase.ready);
      radio.move(RadioPhase.reconnecting);
      radio.move(RadioPhase.connecting);
      radio.move(RadioPhase.ready);
      await settle();
      expect(alerts.calls, ['lost', 'restored']);
      expect(container.read(linkAlertsProvider), 1);
    });

    test('disabled alert still counts the drop but stays silent', () async {
      final alerts = RecordingLinkAlerts();
      final container = ProviderContainer(
        overrides: [
          linkAlertServiceProvider.overrideWithValue(alerts),
          radioProvider.overrideWith(PhaseRadio.new),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(fieldSettingsProvider.notifier)
          .update((s) => s.copyWith(disconnectAlert: false));
      container.read(linkAlertsProvider);
      final radio = container.read(radioProvider.notifier) as PhaseRadio;
      radio.move(RadioPhase.ready);
      radio.move(RadioPhase.failed);
      await settle();
      expect(alerts.calls, isEmpty);
      expect(container.read(linkAlertsProvider), 1);
    });
  });

  test('exports include altitude when the fix has one', () {
    final session = MappingSession(
      id: '1',
      started: base,
      ended: base,
      points: [GpsPoint(35, -80, 5, base, altitude: 212.5)],
      observations: [
        CoverageObservation(
          point: GpsPoint(35, -80, 5, base, altitude: 212.5),
          rssi: -90,
          snr: 2,
          time: base,
        ),
      ],
    );
    final csv = exportSession(session, ExportFormat.csv).split('\r\n');
    expect(csv.first, contains('"altitude_m"'));
    expect(csv[1], contains('"212.5"'));
    final geo = jsonDecode(
      exportSession(session, ExportFormat.geoJson),
    ) as Map<String, dynamic>;
    final features = (geo['features'] as List).cast<Map<String, dynamic>>();
    expect(
      features.every(
        (f) => (f['properties'] as Map<String, dynamic>)['altitude_m'] == 212.5,
      ),
      isTrue,
    );
  });
}
