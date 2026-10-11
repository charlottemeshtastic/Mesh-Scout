import 'dart:io';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/backup/backup.dart';
import 'package:mesh_scout/features/messages/messages.dart';
import 'package:mesh_scout/features/mapping/field_tools.dart';
import 'package:mesh_scout/features/mapping/mapping_notifier.dart';
import 'package:mesh_scout/features/nodes/repeater_details.dart';
import 'package:mesh_scout/features/offline/offline_maps.dart';
import 'package:mesh_scout/features/radio/radio_notifier.dart';
import 'package:mesh_scout/features/sync/cloud_sync.dart';
import 'package:mesh_scout/features/sync/sync_engine.dart';

class IdleSyncRadio extends RadioNotifier {
  @override
  RadioState build() => const RadioState();
}
class IdleSyncMapping extends MappingNotifier {
  @override
  MappingState build() => const MappingState(loading:false);
}
class FakeSyncService implements CloudSyncService {
  final actor = 'a' * 32;
  final calls = <String>[];
  String notes = '[]', baseline = 'null';
  List<String> incoming = [];
  bool failPublish = false;
  @override
  Future<dynamic> call(String method,[Map<String,dynamic>? args]) async {
    calls.add(method);
    switch(method) {
      case 'syncStatus': return {'enabled':true,'folder':'test-folder'};
      case 'syncLocal': return {'actor':actor,'sequence':2,'data':const ScoutBackup([],[]).encode(),'notes':notes,'repeaters':'[]','state':baseline};
      case 'syncRead': return incoming;
      case 'syncPublish': if(failPublish)throw StateError('Offline provider');return true;
      case 'syncApply': return true;
      default: throw StateError('Unexpected operation');
    }
  }
}
void main() {
  late Directory root;
  late ProviderContainer container;
  late FakeSyncService service;
  setUp(() async {
    root=await Directory.systemTemp.createTemp('scout-sync-test');service=FakeSyncService();
    container=ProviderContainer(overrides:[cloudSyncServiceProvider.overrideWithValue(service),
      radioProvider.overrideWith(IdleSyncRadio.new),mappingProvider.overrideWith(IdleSyncMapping.new),
      dataDirectoryProvider.overrideWithValue(() async => root.path),mapDirectoryProvider.overrideWithValue(() async => '${root.path}/offline'),
      syncIntervalProvider.overrideWithValue(const Duration(days:1))]);
    await container.read(messagesProvider.notifier).load();
    await container.read(fieldNotesProvider.future);await container.read(repeaterDetailsProvider.future);
    await container.read(cloudSyncProvider.notifier).initialize();
  });
  tearDown(() async { container.dispose();await root.delete(recursive:true); });
  test('failed publication never applies incoming data and releases maintenance',() async {
    service.failPublish=true;
    await container.read(cloudSyncProvider.notifier).run();
    expect(service.calls,contains('syncPublish'));expect(service.calls, isNot(contains('syncApply')));
    expect(container.read(maintenanceProvider),false);expect(container.read(cloudSyncProvider).attention,true);
  });
  test('conflicts pause automatic sync before any upload or apply',() async {
    Map<String,dynamic> n(String text) => {'id':'n','name':'Trail','note':text,'lat':35.0,'lon':-80.0};
    service.notes=jsonEncode([n('local')]);
    service.baseline=SyncSnapshot(service.actor,1,{'note:n':SyncRecord('note:n',1,service.actor,n('old'))}).encode();
    final b='b'*32;
    service.incoming=[SyncSnapshot(b,1,{'note:n':SyncRecord('note:n',2,b,n('remote'))}).encode()];
    await container.read(cloudSyncProvider.notifier).run();
    expect(service.calls,isNot(contains('syncPublish')));expect(service.calls,isNot(contains('syncApply')));
    expect(container.read(cloudSyncProvider).attention,true);expect(container.read(maintenanceProvider),false);
  });
  test('unchanged snapshots do not repeatedly write cloud files or profiles',() async {
    service.baseline=SyncSnapshot(service.actor,1,{}).encode();
    service.incoming=[service.baseline];
    await container.read(cloudSyncProvider.notifier).run();
    expect(service.calls,contains('syncRead'));expect(service.calls,isNot(contains('syncPublish')));
    expect(container.read(cloudSyncProvider).notice,contains('up to date'));
  });
  test('background sync is deferred without reading the provider',() async {
    container.read(cloudSyncProvider.notifier).foreground(false);
    await container.read(cloudSyncProvider.notifier).run();
    expect(service.calls,['syncStatus']);
  });
}
