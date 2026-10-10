import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/alerts/message_alerts.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';

class AlertRadio extends RadioNotifier {
  void event(List<int> bytes) {
    state = state.copyWith(messageEvent: bytes);
  }

  void phase(RadioPhase phase) {
    state = state.copyWith(phase: phase);
  }
}

class FakeAlerts implements AlertService {
  bool enabled = false;
  bool permission = true;
  bool fails = false;
  int configurations = 0, waitingCalls = 0, clears = 0;
  Completer<void>? gate;
  @override
  Future<bool> load() async => enabled;
  @override
  Future<bool> configure(bool value) async {
    configurations++;
    await gate?.future;
    if (fails) {
      throw StateError('save failed');
    }
    enabled = value && permission;
    return enabled;
  }

  @override
  Future<void> waiting() async {
    if (fails) {
      throw StateError('post failed');
    }
    waitingCalls++;
  }

  @override
  Future<bool> consumeOpen() async => false;
  @override
  Future<void> clear() async {
    clears++;
  }
}

void main() {
  late ProviderContainer container;
  late FakeAlerts service;
  late AlertRadio radio;
  late MessageAlerts alerts;
  setUp(() {
    service = FakeAlerts();
    container = ProviderContainer(overrides: [
      alertServiceProvider.overrideWithValue(service),
      radioProvider.overrideWith(AlertRadio.new)
    ]);
    radio = container.read(radioProvider.notifier) as AlertRadio;
    alerts = container.read(messageAlertsProvider.notifier);
  });
  tearDown(() {
    container.dispose();
  });
  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('startup loads preference without requesting permission', () async {
    service.enabled = true;
    await alerts.initialize();
    expect(container.read(messageAlertsProvider).enabled, true);
    expect(service.configurations, 0);
  });
  test('waiting pushes alert only after opt-in; ACK and malformed push do not',
      () async {
    await alerts.initialize();
    radio.event([0x83]);
    await settle();
    expect(service.waitingCalls, 0);
    await alerts.configure(true);
    radio.event([0x83]);
    radio.event([0x82, 1]);
    radio.event([0x83, 0]);
    await settle();
    expect(service.waitingCalls, 1);
  });
  test('permission denial leaves alerts disabled without affecting radio state',
      () async {
    service.permission = false;
    radio.phase(RadioPhase.ready);
    await alerts.configure(true);
    expect(container.read(messageAlertsProvider).enabled, false);
    expect(container.read(messageAlertsProvider).notice, contains('blocked'));
    expect(container.read(radioProvider).phase, RadioPhase.ready);
  });
  test('disconnect clears waiting alert and opt-out blocks later pushes',
      () async {
    await alerts.configure(true);
    radio.phase(RadioPhase.ready);
    radio.event([0x83]);
    await settle();
    radio.phase(RadioPhase.idle);
    await settle();
    expect(service.clears, 1);
    await alerts.configure(false);
    radio.event([0x83]);
    await settle();
    expect(service.waitingCalls, 1);
  });
  test('failed settings save retains previous preference and reports failure',
      () async {
    await alerts.configure(true);
    service.fails = true;
    await alerts.configure(false);
    expect(container.read(messageAlertsProvider).enabled, true);
    expect(container.read(messageAlertsProvider).notice,
        contains('Could not save'));
  });
  test('permission request remains single-flight', () async {
    service.gate = Completer<void>();
    final first = alerts.configure(true);
    await settle();
    await alerts.configure(true);
    expect(service.configurations, 1);
    service.gate!.complete();
    await first;
    expect(container.read(messageAlertsProvider).busy, false);
  });
  test('posting failure is handled without breaking the radio listener',
      () async {
    await alerts.configure(true);
    service.fails = true;
    radio.event([0x83]);
    await settle();
    expect(container.read(messageAlertsProvider).notice,
        contains('could not be updated'));
    service.fails = false;
    radio.event([0x83]);
    await settle();
    expect(service.waitingCalls, 1);
  });
}
