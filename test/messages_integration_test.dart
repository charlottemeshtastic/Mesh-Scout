import 'dart:io';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/messages/messages.dart';
import 'package:mesh_scout/features/offline/offline_maps.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/radio/ble_service.dart';
import 'radio_test.dart' show FakeBle;

class MessageBle extends FakeBle {
  int fetches = 0;
  bool immediateAck = false;
  bool malformedAcceptance = false;
  bool missingChannel = false;
  bool malformedChannel = false;
  @override
  Future<void> write(String id, List<int> bytes) async {
    if (bytes.first == 22) {
      writes.add(bytes);
      packets.add([13, 3, 0, 2, ...List.filled(76, 0)]);
    } else if (bytes.first == 31) {
      writes.add(bytes);
      if (bytes[1] == 1 || missingChannel) {
        packets.add([1, 2]);
      } else {
        packets.add(malformedChannel
            ? [18, 0]
            : [
                18,
                0,
                80,
                117,
                98,
                108,
                105,
                99,
                ...List.filled(26, 0),
                ...List.filled(16, 254)
              ]);
      }
    } else if (bytes.first == 3) {
      writes.add(bytes);
      packets.add([0]);
    } else if (bytes.first == 2) {
      writes.add(bytes);
      packets
          .add(malformedAcceptance ? [6] : [6, 0, 42, 0, 0, 0, 100, 0, 0, 0]);
      if (immediateAck) {
        packets.add([0x82, 42, 0, 0, 0, 1, 0, 0, 0]);
      }
    } else if (bytes.first == 10) {
      writes.add(bytes);
      fetches++;
      packets.add(
          fetches == 1 ? [7, 1, 2, 3, 4, 5, 6, 0, 0, 1, 0, 0, 0, 65] : [10]);
    } else {
      await super.write(id, bytes);
    }
  }
}

void main() {
  late Directory directory;
  late ProviderContainer container;
  late MessageBle ble;
  late RadioNotifier radio;
  late Messages messages;
  void Function()? inboxTick;
  final key = List.filled(32, 'ab').join();
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('meshscout-messages-');
    ble = MessageBle();
    inboxTick = null;
    container = ProviderContainer(overrides: [
      bleServiceProvider.overrideWithValue(ble),
      inboxTimerProvider.overrideWithValue((duration, tick) {
        final timer = Timer(const Duration(days: 1), () {});
        inboxTick = () { if (timer.isActive) tick(timer); };
        return timer;
      }),
      offlineDirectoryProvider.overrideWithValue(() async => directory.path)
    ]);
    radio = container.read(radioProvider.notifier);
    await radio.scan();
    const device = RadioDevice('radio', 'MeshCore', -60);
    ble.devices.add(device);
    await radio.connect(device);
    ble.links.add(RadioLink.connected);
    for (var i = 0;
        i < 30 && container.read(radioProvider).phase != RadioPhase.ready;
        i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(radioProvider).phase, RadioPhase.ready);
    await radio.refreshContacts();
    ble.packets.add([2, 1, 0, 0, 0]);
    final contact = List<int>.filled(148, 0)
      ..[0] = 3
      ..[33] = 1;
    for (var i = 1; i <= 32; i++) {
      contact[i] = 171;
    }
    ble.packets.add(contact);
    ble.packets.add([4, 0, 0, 0, 0]);
    messages = container.read(messagesProvider.notifier);
    await messages.load();
  });
  tearDown(() async {
    container.dispose();
    await ble.close();
    await directory.delete(recursive: true);
  });
  test('automatic inbox is opt-in, retrieves while idle, and stops when disabled', () async {
    expect(inboxTick, isNull);
    container.read(autoInboxProvider.notifier).set(true);
    inboxTick!();
    for (var i = 0; i < 200 && (ble.fetches < 2 || container.read(messagesProvider).busy); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(ble.fetches, 2);
    expect(container.read(messagesProvider).items.single['body'], 'A');
    expect(ble.writes.where((b) => b.first == 2 || b.first == 3), isEmpty);
    container.read(autoInboxProvider.notifier).set(false);
    inboxTick!();
    await Future<void>.delayed(Duration.zero);
    expect(ble.fetches, 2);
  });
  test('configured channel names omit keys and unused slots', () async {
    await radio.refreshChannels();
    expect(container.read(radioProvider).channels.single.name, 'Public');
    expect(container.read(radioProvider).channels.single.index, 0);
    final reply = await radio.messageCommand([31, 0], {18});
    expect(reply.length, 34);
    expect(reply, isNot(contains(254)));
  });
  test('channel acceptance stays unconfirmed even after a direct ACK',
      () async {
    await radio.refreshChannels();
    await messages.send('', 'hello channel', channel: 0);
    ble.packets.add([0x82, 42, 0, 0, 0, 1, 0, 0, 0]);
    expect(container.read(messagesProvider).items.single['status'],
        contains('channel delivery unconfirmed'));
    expect(ble.writes.where((b) => b.first == 3).length, 1);
    expect(await File('${directory.path}/messages.json').readAsString(),
        isNot(contains('secret')));
  });
  test('missing channel slots do not poison later message commands', () async {
    ble.missingChannel = true;
    await radio.refreshChannels();
    expect(container.read(radioProvider).channels, isEmpty);
    await messages.send(key, 'direct still works');
    expect(container.read(messagesProvider).items.single['status'],
        contains('unconfirmed'));
  });
  test('malformed channel response blocks another command until reconnect',
      () async {
    ble.malformedChannel = true;
    await radio.refreshChannels();
    expect(container.read(radioProvider).channels, isEmpty);
    await expectLater(radio.messageCommand([10], {10}), throwsStateError);
  });
  test('accepted send remains unconfirmed without ACK and is persisted',
      () async {
    await messages.send(key, 'hello');
    expect(container.read(messagesProvider).items.single['status'],
        contains('unconfirmed'));
    expect(ble.writes.where((b) => b.first == 2).length, 1);
    expect(await File('${directory.path}/messages.json').readAsString(),
        contains('hello'));
  });
  test('ACK during write is retained until acceptance and storage complete',
      () async {
    ble.immediateAck = true;
    await messages.send(key, 'hello');
    for (var i = 0;
        i < 200 &&
            container.read(messagesProvider).items.single['status'] !=
                'Delivery confirmed';
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(messagesProvider).items.single['status'],
        'Delivery confirmed');
  });
  test('fetch persists each message before requesting the next', () async {
    await messages.fetch();
    expect(ble.fetches, 2);
    expect(container.read(messagesProvider).items.single['body'], 'A');
    expect(await File('${directory.path}/messages.json').readAsString(),
        contains('Received'));
  });
  test(
      'failed persistence stops retrieval and explicit retry preserves popped data',
      () async {
    await Directory('${directory.path}/messages.json.pending').create();
    await messages.fetch();
    expect(ble.fetches, 1);
    expect(container.read(messagesProvider).notice, contains('Save failed'));
    await Directory('${directory.path}/messages.json.pending').delete();
    await messages.retrySave();
    for (var i = 0;
        i < 200 &&
            container.read(messagesProvider).items.single['status'] !=
                'Delivery confirmed';
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(container.read(messagesProvider).items.single['body'], 'A');
    expect(await File('${directory.path}/messages.json').readAsString(),
        contains('Received'));
  });
  test('malformed acceptance is never retried and blocks another command',
      () async {
    ble.malformedAcceptance = true;
    await messages.send(key, 'hello');
    expect(ble.writes.where((b) => b.first == 2).length, 1);
    expect(container.read(messagesProvider).items.single['status'],
        contains('unknown'));
    await expectLater(radio.messageCommand([10], {10}), throwsStateError);
  });
}
