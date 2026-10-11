import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/common/mesh_data.dart';
import 'package:mesh_scout/features/radio/ble_service.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/mapping/mapping_notifier.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';

import 'radio_test.dart' show FakeBle;
import 'mapping_test.dart' show FakeMapping;

List<int> contactFrame({int key = 1, String name = 'Test repeater'}) {
  final bytes = Uint8List(148);
  bytes[0] = 3;
  bytes[1] = key;
  bytes[33] = 2;
  bytes.setRange(100, 100 + utf8.encode(name).length, utf8.encode(name));
  final data = ByteData.sublistView(bytes);
  data.setUint32(132, 1700000000, Endian.little);
  data.setInt32(136, 35200000, Endian.little);
  data.setInt32(140, -80800000, Endian.little);
  return bytes;
}

List<int> countFrame(int code, int count) {
  final bytes = Uint8List(5);
  bytes[0] = code;
  ByteData.sublistView(bytes).setUint32(1, count, Endian.little);
  return bytes;
}

class FeatureBle extends FakeBle {
  int connections = 0;
  int ended = 0;
  @override
  Stream<RadioLink> connect(String id) {
    connections++;
    return super.connect(id);
  }

  @override
  Future<void> endSession() async {
    ended++;
  }

  @override
  Future<void> write(String id, List<int> bytes) async {
    if (bytes.first == 4) {
      writes.add(bytes);
      return;
    }
    await super.write(id, bytes);
  }
}

class ManualTimer implements Timer {
  ManualTimer(this.callback);
  final void Function() callback;
  bool _active = true;
  void fire() {
    if (_active) {
      _active = false;
      callback();
    }
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
  @override
  void cancel() {
    _active = false;
  }
}

void main() {
  Future<void> flush() async {
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  late FeatureBle ble;
  late List<ManualTimer> retryTimers;
  late ProviderContainer container;
  late RadioNotifier actions;
  setUp(() {
    ble = FeatureBle();
    retryTimers = [];
    container = ProviderContainer(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        reconnectTimerProvider.overrideWithValue((duration, callback) {
          final timer = ManualTimer(callback);
          retryTimers.add(timer);
          return timer;
        }),
      ],
    );
    actions = container.read(radioProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await flush();
    await ble.close();
  });
  Future<void> ready() async {
    await actions.scan();
    const device = RadioDevice('radio', 'Companion', -55);
    ble.devices.add(device);
    await actions.connect(device);
    ble.links.add(RadioLink.connected);
    await flush();
    expect(container.read(radioProvider).phase, RadioPhase.ready);
  }

  test('contact parser decodes signed coordinates, key and name', () {
    final contact = MeshContact.parse(contactFrame());
    expect(contact.latitude, 35.2);
    expect(contact.longitude, -80.8);
    expect(contact.typeLabel, 'Repeater');
    expect(contact.key.length, 64);
    expect(contact.name, 'Test repeater');
    expect(() => MeshContact.parse([3, 1]), throwsFormatException);
  });
  test('contact stream commits only after validated start/count/end', () async {
    await ready();
    await actions.refreshContacts();
    ble.packets.add(countFrame(2, 2));
    ble.packets.add(contactFrame(key: 1));
    expect(container.read(radioProvider).contacts, isEmpty);
    ble.packets.add(contactFrame(key: 2, name: 'Alpha'));
    ble.packets.add(countFrame(4, 0));
    final state = container.read(radioProvider);
    expect(state.syncing, false);
    expect(state.contacts.length, 2);
    expect(state.contacts.first.name, 'Alpha');
    expect(state.syncedAt, isNotNull);
  });
  test(
    'incomplete contact stream is rejected and retry requires reconnect',
    () async {
      await ready();
      await actions.refreshContacts();
      ble.packets.add(countFrame(2, 2));
      ble.packets.add(contactFrame());
      ble.packets.add(countFrame(4, 0));
      expect(container.read(radioProvider).contacts, isEmpty);
      expect(
        container.read(radioProvider).contactMessage,
        contains('Incomplete'),
      );
      final writes = ble.writes.length;
      await actions.refreshContacts();
      expect(ble.writes.length, writes);
    },
  );
  test('insufficient RF frame MTU blocks identification and contact refresh', () async {
    ble.mtu = 100;
    await actions.scan();
    const device = RadioDevice('radio', 'Companion', -55);
    ble.devices.add(device);
    await actions.connect(device);
    ble.links.add(RadioLink.connected);
    await flush();
    expect(container.read(radioProvider).phase, RadioPhase.failed);
    expect(container.read(radioProvider).failure, RadioFailure.protocol);
    await actions.refreshContacts();
    expect(container.read(radioProvider).syncing, false);
    expect(ble.writes.where((b) => b.first == 4), isEmpty);
  });
  test(
    'empty contact list is valid; unsolicited RX data never becomes a contact',
    () async {
      await ready();
      await actions.refreshContacts();
      ble.packets.add([0x88, 0xf8, 0x9c, 0x11, 0, 0xaa]);
      ble.packets.add(countFrame(2, 0));
      ble.packets.add(countFrame(4, 0));
      expect(container.read(radioProvider).contacts, isEmpty);
      expect(container.read(radioProvider).syncedAt, isNotNull);
      expect(container.read(radioProvider).lastRx?.rssi, -100);
      expect(container.read(radioProvider).lastRx?.snr, -2);
    },
  );
  test(
    'identified link retries, re-identifies, and retains the radio service',
    () async {
      await ready();
      expect(actions.beginControls(), isTrue);
      ble.links.add(RadioLink.disconnected);
      await flush();
      expect(container.read(radioProvider).phase, RadioPhase.reconnecting);
      expect(ble.ended, 0);
      expect(container.read(radioProvider).controlsBusy, isFalse);
      retryTimers.last.fire();
      await flush();
      expect(ble.connections, 2);
      ble.links.add(RadioLink.connected);
      await flush();
      expect(container.read(radioProvider).phase, RadioPhase.ready);
      expect(actions.beginControls(), isTrue);
      actions.endControls(actions.sessionToken);
      expect(ble.writes.where((b) => b.first == 1).length, 2);
    },
  );
  test('manual disconnect cancels reconnect and releases service', () async {
    await ready();
    ble.links.add(RadioLink.disconnected);
    await flush();
    await actions.disconnect();
    retryTimers.last.fire();
    await flush();
    expect(ble.connections, 1);
    expect(ble.ended, 1);
    expect(container.read(radioProvider).phase, RadioPhase.idle);
  });
  test(
    'turning off auto reconnect leaves link loss as a manual recovery',
    () async {
      await ready();
      await actions.setAutoReconnect(false);
      ble.links.add(RadioLink.disconnected);
      await flush();
      expect(retryTimers, isEmpty);
      expect(ble.connections, 1);
      expect(ble.ended, 1);
      expect(container.read(radioProvider).phase, RadioPhase.failed);
    },
  );
  test('reconnect stops after five unsuccessful attempts', () async {
    await ready();
    ble.links.add(RadioLink.disconnected);
    await flush();
    for (var i = 0; i < 5; i++) {
      retryTimers.last.fire();
      await flush();
      ble.links.add(RadioLink.disconnected);
      await flush();
    }
    expect(ble.connections, 6);
    expect(ble.ended, 1);
    expect(container.read(radioProvider).phase, RadioPhase.failed);
  });
  test('RX parser uses signed quarter-dB SNR and rejects unrelated frames', () {
    final now = DateTime.now();
    expect(
        RxObservation.parse([0x88, 0xfc, 0x88, 1, 0, 0xaa], now)?.rssi, -120);
    expect(RxObservation.parse([0x88, 0xfc, 0x88, 1, 0, 0xaa], now)?.snr, -1);
    expect(RxObservation.parse([0x88, 1], now), isNull);
    expect(RxObservation.parse([0x83, 0xfc, 0x88, 1], now), isNull);
  });
  test(
    'coverage requires recording and recent GPS; saves and reopens metrics',
    () async {
      final gps = FakeMapping();
      final mapping = ProviderContainer(
        overrides: [mappingServiceProvider.overrideWithValue(gps)],
      );
      final actions = mapping.read(mappingProvider.notifier);
      await actions.initialize();
      final now = DateTime.now();
      actions.capture(RxObservation(-100, 3, now));
      expect(mapping.read(mappingProvider).observations, isEmpty);
      await actions.start();
      gps.updates.add(GpsPoint(35.2, -80.8, 5, now));
      actions.capture(
        RxObservation(-100, 3, now.add(const Duration(seconds: 16))),
      );
      expect(mapping.read(mappingProvider).observations, isEmpty);
      actions.capture(
        RxObservation(-105, -1.5, now.add(const Duration(seconds: 1))),
      );
      expect(mapping.read(mappingProvider).observations.length, 1);
      await actions.stop();
      final saved = decodeSessions(gps.stored).single;
      expect(saved.observations.single.rssi, -105);
      expect(saved.observations.single.snr, -1.5);
      expect(saved.observations.single.point.latitude, 35.2);
      mapping.dispose();
      await gps.updates.close();
    },
  );
  test('old GPS-only sessions load without an observations field', () {
    final json =
        '[{"id":"old","started":"2026-10-10T00:00:00Z","ended":"2026-10-10T00:01:00Z","points":[]}]';
    expect(decodeSessions(json).single.observations, isEmpty);
  });
}
