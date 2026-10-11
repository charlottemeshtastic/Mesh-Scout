import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/common/mesh_data.dart';
import 'package:mesh_scout/features/mapping/mapping_notifier.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';
import 'package:mesh_scout/features/mapping/smart_ping.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/settings/field_settings.dart';

class PingRadio extends RadioNotifier {
  final sent = <List<int>>[];
  Completer<List<int>>? reply;
  @override
  RadioState build() => const RadioState(
      phase: RadioPhase.ready,
      preset:
          RadioPreset(frequencyKhz: 915000, bandwidthHz: 125000, sf: 7, cr: 5));
  @override
  Future<List<int>> messageCommand(List<int> command, Set<int> replies,
      {bool allowNotFound = false, bool control = false}) async {
    sent.add(command);
    return reply == null ? [0] : await reply!.future;
  }
}

class PingMapping extends MappingNotifier {
  PingMapping(this.initial);
  final MappingState initial;
  @override
  MappingState build() => initial;
  void recording(bool value) => state =
      MappingState(loading: false, recording: value, points: state.points);
}

void main() {
  final now = DateTime.utc(2026, 10, 11);
  GpsPoint point({DateTime? time, double accuracy = 5}) =>
      GpsPoint(35.1, -80.1, accuracy, time ?? now);
  MappingSession measured(String preset, DateTime time) => MappingSession(
      id: 's',
      started: time,
      ended: time,
      points: [point(time: time)],
      preset: preset,
      observations: [
        CoverageObservation(
            point: point(time: time), rssi: -100, snr: 1, time: time)
      ]);
  test('recent measured cells honor preset, age and planned route exclusion',
      () {
    expect(
        recentlyMeasured(point(), [measured('p', now)],
            now: now, days: 14, preset: 'p'),
        true);
    expect(
        recentlyMeasured(point(), [measured('other', now)],
            now: now, days: 14, preset: 'p'),
        false);
    expect(
        recentlyMeasured(
            point(), [measured('p', now.subtract(const Duration(days: 15)))],
            now: now, days: 14, preset: 'p'),
        false);
    expect(
        recentlyMeasured(
            point(), [measured('p', now.add(const Duration(seconds: 1)))],
            now: now, days: 14, preset: 'p'),
        false);
  });
  test('manual and automatic sends share rate limiting and do not add coverage',
      () async {
    final radio = PingRadio();
    final mapping = PingMapping(
        MappingState(loading: false, recording: true, points: [point()]));
    final container = ProviderContainer(overrides: [
      radioProvider.overrideWith(() => radio),
      mappingProvider.overrideWith(() => mapping),
      mappingClockProvider.overrideWithValue(() => now)
    ]);
    addTearDown(container.dispose);
    container
        .read(fieldSettingsProvider.notifier)
        .update((s) => s.copyWith(smartPing: true));
    final actions = container.read(smartPingProvider.notifier);
    await actions.send();
    await actions.send(manual: true);
    expect(radio.sent, [
      [7, 0]
    ]);
    expect(container.read(smartPingProvider).sent, 1);
    expect(container.read(mappingProvider).observations, isEmpty);
  });
  test('stale GPS, background and stopped recording never send', () async {
    for (final stale in [true, false]) {
      final radio = PingRadio();
      final mapping = PingMapping(MappingState(
          loading: false,
          recording: true,
          points: [
            point(time: stale ? now.subtract(const Duration(seconds: 16)) : now)
          ]));
      final container = ProviderContainer(overrides: [
        radioProvider.overrideWith(() => radio),
        mappingProvider.overrideWith(() => mapping),
        mappingClockProvider.overrideWithValue(() => now)
      ]);
      final actions = container.read(smartPingProvider.notifier);
      if (!stale) actions.foreground(false);
      await actions.send(manual: true);
      mapping.recording(false);
      actions.foreground(true);
      await actions.send(manual: true);
      expect(radio.sent, isEmpty);
      container.dispose();
    }
  });
  test('stop while awaiting acceptance prevents any new automatic sends',
      () async {
    final radio = PingRadio()..reply = Completer<List<int>>();
    final mapping = PingMapping(
        MappingState(loading: false, recording: true, points: [point()]));
    final container = ProviderContainer(overrides: [
      radioProvider.overrideWith(() => radio),
      mappingProvider.overrideWith(() => mapping),
      mappingClockProvider.overrideWithValue(() => now)
    ]);
    addTearDown(container.dispose);
    container
        .read(fieldSettingsProvider.notifier)
        .update((s) => s.copyWith(smartPing: true));
    final actions = container.read(smartPingProvider.notifier);
    final pending = actions.send();
    container
        .read(fieldSettingsProvider.notifier)
        .update((s) => s.copyWith(smartPing: false));
    radio.reply!.complete([0]);
    await pending;
    await actions.send();
    expect(radio.sent.length, 1);
    expect(container.read(smartPingProvider).busy, false);
  });
}
