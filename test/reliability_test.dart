import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/messages/messages.dart';
import 'package:mesh_scout/features/radio/inbox_journal.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/offline/offline_maps.dart';
import 'package:mesh_scout/features/backup/preferences.dart';
import 'package:mesh_scout/common/mesh_data.dart';
import 'package:mesh_scout/features/mapping/mapping_notifier.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';
import 'radio_test.dart' show FakeBle;
import 'mapping_test.dart' show FakeMapping;

class CheckpointMapping extends FakeMapping implements CheckpointMappingService {
  final checkpoints = <MappingSession>[];
  @override
  Future<void> checkpoint(MappingSession session) async { checkpoints.add(session); }
}
void main() {
  late Directory directory;
  late ProviderContainer container;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('meshscout-reliability-');
    container = ProviderContainer(overrides: [offlineDirectoryProvider.overrideWithValue(() async => directory.path),
      bleServiceProvider.overrideWithValue(FakeBle())]);
  });
  tearDown(() async { container.dispose(); await directory.delete(recursive: true); });
  Map<String,dynamic> message(int n) => {'peer': 'peer', 'body': '$n', 'radio': 'radio', 'time': n,
    'outgoing': false, 'status': 'Received', 'unread': true};
  test('inbox checkpoint survives restart and replays once after history was published', () async {
    final journal = container.read(inboxJournalProvider);
    await journal.write([7,1,2,3,4,5,6,0,0,1,0,0,0,65], 'radio');
    final checkpoint = await journal.read();
    await File('${directory.path}/messages.json').writeAsString(jsonEncode([
      {...recoveredMessage(List<int>.from(checkpoint!['frame'] as List)), 'radio': 'radio', '_checkpoint': jsonEncode(checkpoint)}]));
    await container.read(messagesProvider.notifier).load();
    expect(container.read(messagesProvider).items.length, 1);
    expect(await journal.read(), isNull);
  });
  test('received checkpoint recovers a message and never overwrites pending data', () async {
    final journal = container.read(inboxJournalProvider);
    await journal.write([7,1,2,3,4,5,6,0,0,1,0,0,0,65], 'radio');
    await expectLater(journal.write([27,0], 'other'), throwsStateError);
    await container.read(messagesProvider.notifier).load();
    expect(container.read(messagesProvider).items.single['body'], 'A');
    expect(unreadCount(container.read(messagesProvider).items), 1);
    expect(await journal.read(), isNull);
  });
  test('unsupported checkpoint is kept as a raw message rather than blocking history', () async {
    await container.read(inboxJournalProvider).write([27,2,255], 'radio');
    await container.read(messagesProvider.notifier).load();
    expect(container.read(messagesProvider).loaded, true);
    expect(container.read(messagesProvider).items.single['body'], '1b 02 ff');
  });
  test('completed pending history recovers and per-conversation read and deletion persist', () async {
    await File('${directory.path}/messages.json.pending').writeAsString(jsonEncode([message(1), {...message(2), 'radio': 'other'}]));
    final actions = container.read(messagesProvider.notifier);
    await actions.load();
    await actions.markRead('radio|peer');
    expect(unreadCount(container.read(messagesProvider).items), 1);
    final removed = container.read(messagesProvider).items.last;
    await actions.deleteMessage(removed);
    expect(container.read(messagesProvider).items.length, 1);
    expect((jsonDecode(await File('${directory.path}/messages.json').readAsString()) as List).length, 1);
  });
  test('partial pending history falls back to the last complete file', () async {
    await File('${directory.path}/messages.json').writeAsString(jsonEncode([message(1)]));
    await File('${directory.path}/messages.json.pending').writeAsString('[{');
    await container.read(messagesProvider.notifier).load();
    expect(container.read(messagesProvider).loaded, true);
    expect(container.read(messagesProvider).items.single['body'], '1');
  });
  test('message pruning keeps latest 200 without touching radio queue', () async {
    await File('${directory.path}/messages.json').writeAsString(jsonEncode(List.generate(250, message)));
    final actions = container.read(messagesProvider.notifier);
    await actions.load(); await actions.pruneHistory();
    expect(container.read(messagesProvider).items.length, 200);
    expect(container.read(messagesProvider).items.first['time'], 50);
  });
  test('preferred radio and matching contacts reload without initiating a disconnected session', () async {
    final frame = List<int>.filled(148,0)..[0]=3..[33]=1;
    await File('${directory.path}/settings.json').writeAsString(jsonEncode({'autoReconnect': false, 'autoInbox': true,
      'preferredRadio': {'id':'radio', 'name':'My radio'}, 'resumeMonitoring':false}));
    await File('${directory.path}/contacts-cache.json').writeAsString(jsonEncode({'radio':'radio', 'synced':DateTime.now().toIso8601String(), 'frames':[frame]}));
    await container.read(preferencesProvider.notifier).initialize();
    expect(container.read(radioProvider.notifier).preferred?.id, 'radio');
    expect(container.read(radioProvider).contacts.single.key, MeshContact.parse(frame).key);
    expect(container.read(radioProvider).phase, RadioPhase.idle);
    expect(container.read(autoInboxProvider), true);
    await container.read(preferencesProvider.notifier).pending;
  });
  test('GPS and associated LoRa observation share a recovery checkpoint before stop', () async {
    final mapping = CheckpointMapping();
    final local = ProviderContainer(overrides:[mappingServiceProvider.overrideWithValue(mapping)]);
    final actions = local.read(mappingProvider.notifier);
    await actions.initialize(); await actions.start();
    final now = DateTime.now();
    mapping.updates.add(GpsPoint(35,-80,5,now));
    actions.capture(RxObservation(-95,3,now.add(const Duration(seconds:1))));
    await actions.stop();
    expect(mapping.checkpoints.last.observations.single.rssi, -95);
    expect(decodeSessions(mapping.stored).single.observations.length, 1);
    local.dispose(); await mapping.updates.close();
  });
}
