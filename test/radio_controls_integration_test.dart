import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_scout/features/radio/radio_controls.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/radio/ble_service.dart';

import 'radio_test.dart' show FakeBle;

class ControlBle extends FakeBle {
  String name = 'Trail';
  int power = 10;
  bool reject = false;
  @override
  Future<void> write(String id, List<int> bytes) async {
    writes.add(bytes);
    if (bytes.first == 1) {
      final self = List<int>.filled(58, 0)
        ..[0] = 5
        ..[2] = power
        ..[3] = 22;
      packets.add([...self, ...utf8.encode(name)]);
    } else if (bytes.first == 22) {
      packets.add([13, 3, 0, 1, 99, 98, 97, 96, ...List.filled(72, 0)]);
    } else if (bytes.first == 20) {
      packets.add([12, 160, 15, 10, 0, 0, 0, 100, 0, 0, 0]);
    } else if ([8, 12, 6].contains(bytes.first)) {
      if (reject) {
        packets.add([1, 2]);
        return;
      }
      if (bytes.first == 8) name = utf8.decode(bytes.sublist(1));
      if (bytes.first == 12) power = bytes[1];
      packets.add([0]);
    }
  }
}

void main() {
  late ProviderContainer container;
  late ControlBle ble;
  late RadioNotifier radio;
  setUp(() async {
    ble = ControlBle();
    container = ProviderContainer(
      overrides: [bleServiceProvider.overrideWithValue(ble)],
    );
    radio = container.read(radioProvider.notifier);
    await radio.scan();
    const device = RadioDevice('radio', 'MeshCore', -50);
    ble.devices.add(device);
    await radio.connect(device);
    ble.links.add(RadioLink.connected);
    for (
      var i = 0;
      i < 50 && container.read(radioProvider).phase != RadioPhase.ready;
      i++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(radioProvider).phase, RadioPhase.ready);
  });
  tearDown(() async {
    container.dispose();
    await ble.close();
  });
  test('status refresh and accepted settings changes read back current radio values', () async {
    final controls = container.read(radioControlsProvider.notifier);
    await controls.refresh();
    expect(container.read(radioControlsProvider).details!.millivolts, 4000);
    await controls.setName('Updated');
    await controls.setPower(18);
    expect(container.read(radioControlsProvider).details!.name, 'Updated');
    expect(container.read(radioControlsProvider).details!.txPower, 18);
    expect(container.read(radioProvider).controlsBusy, isFalse);
    final device = await radio.messageCommand(deviceQuery, {13});
    expect(device.sublist(4, 8), [0, 0, 0, 0]);
  });
  test('control lock blocks message/contact operations and is cleared on disconnect', () async {
    expect(radio.beginControls(), isTrue);
    await expectLater(radio.messageCommand([10], {10}), throwsStateError);
    await radio.refreshContacts();
    await radio.refreshChannels();
    expect(container.read(radioProvider).syncing, isFalse);
    expect(container.read(radioProvider).channelsLoading, isFalse);
    await radio.disconnect();
    expect(container.read(radioProvider).controlsBusy, isFalse);
  });
  test('rejected mutation is not retried and requires reconnect before another request', () async {
    final controls = container.read(radioControlsProvider.notifier);
    await controls.refresh();
    ble.reject = true;
    await controls.setName('Rejected');
    expect(ble.writes.where((b) => b.first == 8).length, 1);
    expect(container.read(radioControlsProvider).notice, contains('Reconnect'));
    await expectLater(radio.messageCommand([20], {12}), throwsStateError);
  });
}
