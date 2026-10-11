import 'dart:async';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/radio/ble_service.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/radio/radio_screen.dart';

class FakeBle implements BleService {
  final devices = StreamController<RadioDevice>.broadcast(sync: true);
  final links = StreamController<RadioLink>.broadcast(sync: true);
  final packets = StreamController<List<int>>.broadcast(sync: true);
  RadioFailure? authorizationFailure;
  bool answer = true;
  bool validServices = true;
  Completer<void>? discoveryGate;
  int scanCalls = 0;
  final writes = <List<int>>[];
  @override
  Future<void> authorize() async {
    if (authorizationFailure case final failure?) {
      throw RadioException(failure);
    }
  }

  @override
  Stream<RadioDevice> scan() {
    scanCalls++;
    return devices.stream;
  }

  @override
  Stream<RadioLink> connect(String id) => links.stream;
  @override
  Future<void> discover(String id) async {
    await discoveryGate?.future;
    if (!validServices) throw const RadioException(RadioFailure.protocol);
  }

  @override
  Stream<List<int>> notifications(String id) => packets.stream;
  @override
  Future<void> write(String id, List<int> bytes) async {
    writes.add(bytes);
    if (answer) {
      packets.add(bytes.first == 1
          ? [5, ...List.filled(57, 0)]
          : [13, 3, ...List.filled(78, 0)]);
    }
  }

  @override
  Future<void> openSettings() async {}
  Future<void> close() async {
    await devices.close();
    await links.close();
    await packets.close();
  }
}

class ManualTimer implements Timer {
  ManualTimer(this.due, this.callback);
  final Duration due;
  final void Function() callback;
  @override
  bool isActive = true;
  @override
  int tick = 0;
  @override
  void cancel() {
    isActive = false;
  }

  void fire() {
    if (isActive) {
      isActive = false;
      tick = 1;
      callback();
    }
  }
}

class ManualScheduler {
  Duration elapsed = Duration.zero;
  final timers = <ManualTimer>[];
  Timer schedule(Duration duration, void Function() callback) {
    final timer = ManualTimer(elapsed + duration, callback);
    timers.add(timer);
    return timer;
  }

  void elapse(Duration duration) {
    elapsed += duration;
    for (final timer in timers.toList()) {
      if (timer.isActive && timer.due <= elapsed) {
        timer.fire();
      }
    }
  }
}

void main() {
  test('Android permission split occurs exactly at API 31', () {
    expect(permissionPlan(30), [BluetoothAccess.location]);
    expect(permissionPlan(31), [BluetoothAccess.scan, BluetoothAccess.connect]);
    expect(permissionPlan(36), [BluetoothAccess.scan, BluetoothAccess.connect]);
  });
  late FakeBle ble;
  late ProviderContainer container;
  late RadioNotifier actions;
  const device = RadioDevice('radio', 'MeshCore-test', -60);
  setUp(() {
    ble = FakeBle();
    container = ProviderContainer(
        overrides: [bleServiceProvider.overrideWithValue(ble)]);
    actions = container.read(radioProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await ble.close();
  });
  Future<void> findRadio() async {
    await actions.scan();
    ble.devices.add(device);
    await actions.stopScan();
    await actions.connect(device);
  }

  Future<void> flush() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  for (final failure in [
    RadioFailure.denied,
    RadioFailure.permanentlyDenied,
    RadioFailure.unavailable
  ]) {
    test('authorization $failure prevents scanning', () async {
      ble.authorizationFailure = failure;
      await actions.scan();
      expect(ble.scanCalls, 0);
      expect(container.read(radioProvider).failure, failure);
    });
  }
  test('deduplicates devices, updates RSSI, stops scan and rejects unknown IDs',
      () async {
    await actions.scan();
    await actions.scan();
    ble.devices.add(device);
    ble.devices.add(const RadioDevice('radio', 'MeshCore-test', -45));
    expect(ble.scanCalls, 1);
    expect(container.read(radioProvider).devices.single.rssi, -45);
    await actions.stopScan();
    expect(ble.devices.hasListener, isFalse);
    await actions.connect(const RadioDevice('unknown', '', 0));
    expect(ble.links.hasListener, isFalse);
  });
  test('serial handshake precedes ready and disconnect releases subscriptions',
      () async {
    await findRadio();
    ble.links.add(RadioLink.connected);
    await flush();
    expect(ble.writes, [appStart, deviceQuery]);
    expect(container.read(radioProvider).phase, RadioPhase.ready);
    await actions.disconnect();
    expect(ble.links.hasListener, isFalse);
    expect(ble.packets.hasListener, isFalse);
    expect(container.read(radioProvider).phase, RadioPhase.idle);
  });
  test('wrong GATT characteristics cannot be ready', () async {
    ble.validServices = false;
    await findRadio();
    ble.links.add(RadioLink.connected);
    await flush();
    expect(container.read(radioProvider).failure, RadioFailure.protocol);
    expect(ble.writes, isEmpty);
  });
  test('unexpected disconnect fails and releases GATT', () async {
    await findRadio();
    ble.links.add(RadioLink.disconnected);
    await flush();
    expect(container.read(radioProvider).failure, RadioFailure.transport);
    expect(ble.links.hasListener, isFalse);
  });
  test('cancel during authorization ignores late permission result', () async {
    final pending = actions.scan();
    await actions.disconnect();
    await pending;
    expect(container.read(radioProvider).phase, RadioPhase.idle);
    expect(ble.scanCalls, 0);
  });
  test('cancel during discovery prevents late handshake writes', () async {
    ble.discoveryGate = Completer<void>();
    await findRadio();
    ble.links.add(RadioLink.connected);
    await flush();
    await actions.disconnect();
    ble.discoveryGate!.complete();
    await flush();
    expect(ble.writes, isEmpty);
    expect(container.read(radioProvider).phase, RadioPhase.idle);
  });
  test('duplicate connected events initialize only once', () async {
    await findRadio();
    ble.links.add(RadioLink.connected);
    ble.links.add(RadioLink.connected);
    await flush();
    expect(ble.writes, [appStart, deviceQuery]);
  });
  testWidgets('permission failure renders recovery and background cancels scan',
      (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const MaterialApp(home: RadioScreen())));
    ble.authorizationFailure = RadioFailure.permanentlyDenied;
    await tester.tap(find.text('Scan for radios'));
    await tester.pumpAndSettle();
    expect(find.text('Open app settings'), findsOneWidget);
    ble.authorizationFailure = null;
    await tester.tap(find.text('Scan for radios'));
    await tester.pumpAndSettle();
    expect(ble.devices.hasListener, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(ble.devices.hasListener, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  test('scan deadline stops after ten seconds', () async {
    container.dispose();
    final scheduler = ManualScheduler();
    container = ProviderContainer(overrides: [
      bleServiceProvider.overrideWithValue(ble),
      radioTimerProvider.overrideWithValue(scheduler.schedule),
    ]);
    actions = container.read(radioProvider.notifier);
    await actions.scan();
    scheduler.elapse(const Duration(seconds: 9));
    await flush();
    expect(container.read(radioProvider).phase, RadioPhase.scanning);
    scheduler.elapse(const Duration(seconds: 1));
    await flush();
    expect(container.read(radioProvider).phase, RadioPhase.idle);
    expect(ble.devices.hasListener, isFalse);
  });
  test('short and unsolicited packets cannot satisfy identification', () async {
    container.dispose();
    final scheduler = ManualScheduler();
    container = ProviderContainer(overrides: [
      bleServiceProvider.overrideWithValue(ble),
      radioTimerProvider.overrideWithValue(scheduler.schedule),
    ]);
    actions = container.read(radioProvider.notifier);
    ble.answer = false;
    await findRadio();
    ble.links.add(RadioLink.connected);
    await flush();
    ble.packets.add([5]);
    ble.packets.add([0x83]);
    scheduler.elapse(const Duration(seconds: 2));
    await flush();
    scheduler.elapse(const Duration(seconds: 2));
    await flush();
    expect(container.read(radioProvider).phase, RadioPhase.failed);
    expect(container.read(radioProvider).failure, RadioFailure.protocol);
    expect(ble.writes, [appStart, appStart]);
    expect(scheduler.timers.any((t) => t.isActive), isFalse);
  });
  test(
      'collection is opt-in after handshake, metadata is bounded and timestamped',
      () async {
    final now = DateTime.utc(2026, 10, 10, 12);
    container.dispose();
    container = ProviderContainer(overrides: [
      bleServiceProvider.overrideWithValue(ble),
      clockProvider.overrideWithValue(Clock.fixed(now)),
    ]);
    actions = container.read(radioProvider.notifier);
    actions.startCollection();
    expect(container.read(radioProvider).collecting, isFalse);
    await findRadio();
    ble.links.add(RadioLink.connected);
    await flush();
    final frame = [0x88, 0xf9, 0x9c, 0x11, 0, 0xaa];
    ble.packets.add(frame);
    expect(container.read(radioProvider).receivedCount, 0);
    actions.startCollection();
    ble.packets.add([0x80, ...List.filled(32, 0)]);
    ble.packets.add([0x88]);
    for (var i = 0; i < 205; i++) {
      ble.packets.add(frame);
    }
    final state = container.read(radioProvider);
    expect(state.receivedCount, 205);
    expect(state.observations.length, maxRadioObservations);
    expect(state.malformedCount, 1);
    expect(state.observations.first.receivedAt, now);
    expect(() => state.observations.clear(), throwsUnsupportedError);
    expect(ble.writes, [appStart, deviceQuery]);
    actions.stopCollection();
    ble.packets.add(frame);
    expect(container.read(radioProvider).receivedCount, 205);
    await actions.disconnect();
    expect(container.read(radioProvider).collecting, isFalse);
    expect(container.read(radioProvider).receivedCount, 205);
    ble.packets.add(frame);
    expect(container.read(radioProvider).receivedCount, 205);
    actions.clearObservations();
    expect(container.read(radioProvider).observations, isEmpty);
    expect(container.read(radioProvider).receivedCount, 0);
    expect(container.read(radioProvider).malformedCount, 0);
  });

  test(
      'link failure stops collection, preserves results; a new scan clears them',
      () async {
    await findRadio();
    ble.links.add(RadioLink.connected);
    await flush();
    actions.startCollection();
    ble.packets.add([0x88, 0, 0x9c, 0x11, 0, 0xaa]);
    ble.links.add(RadioLink.disconnected);
    await flush();
    final state = container.read(radioProvider);
    expect(state.phase, RadioPhase.failed);
    expect(state.collecting, isFalse);
    expect(state.receivedCount, 1);
    expect(ble.packets.hasListener, isFalse);
    await actions.scan();
    expect(container.read(radioProvider).observations, isEmpty);
  });

  testWidgets(
      'live RF view starts, stops and clears; background stops collection',
      (tester) async {
    await tester.runAsync(() async {
      await findRadio();
      ble.links.add(RadioLink.connected);
      await flush();
    });
    await tester.pumpWidget(UncontrolledProviderScope(
        container: container, child: const MaterialApp(home: RadioScreen())));
    await tester.ensureVisible(find.text('Start collecting'));
    await tester.tap(find.text('Start collecting'));
    await tester.pump();
    ble.packets.add([0x88, 0xf9, 0x9c, 0x11, 0, 0xaa]);
    await tester.pump();
    expect(find.text('LoRa RSSI -100 dBm · SNR -1.75 dB'), findsOneWidget);
    await tester.ensureVisible(find.text('Stop collecting'));
    await tester.tap(find.text('Stop collecting'));
    await tester.pump();
    expect(container.read(radioProvider).collecting, isFalse);
    await tester.ensureVisible(find.text('Clear observations'));
    await tester.tap(find.text('Clear observations'));
    await tester.pump();
    expect(container.read(radioProvider).observations, isEmpty);
    await tester.ensureVisible(find.text('Start collecting'));
    await tester.tap(find.text('Start collecting'));
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await flush();
    });
    await tester.pump();
    expect(container.read(radioProvider).collecting, isFalse);
    expect(ble.packets.hasListener, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
