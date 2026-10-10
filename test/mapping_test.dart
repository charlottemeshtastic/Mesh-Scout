import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/mapping/mapping_notifier.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';

class FakeMapping implements MappingService, BackgroundMappingService {
  bool backgroundEnabled = false;
  @override
  Future<void> configureRecording(bool background, DateTime started) async {
    backgroundEnabled = background;
  }

  final updates = StreamController<GpsPoint>.broadcast(sync: true);
  String? stored;
  bool denied = false;
  bool saveFails = false;
  Completer<void>? permissionGate;
  int authorizations = 0;
  @override
  Future<void> authorize() async {
    authorizations++;
    await permissionGate?.future;
    if (denied) throw Exception('Permission denied');
  }

  @override
  Stream<GpsPoint> positions() => updates.stream;
  @override
  Future<String?> load() async => stored;
  @override
  Future<void> save(String json) async {
    if (saveFails) throw Exception('Storage failure');
    stored = json;
  }
}

void main() {
  late FakeMapping service;
  late ProviderContainer container;
  late MappingNotifier actions;
  setUp(() async {
    service = FakeMapping();
    container = ProviderContainer(
        overrides: [mappingServiceProvider.overrideWithValue(service)]);
    actions = container.read(mappingProvider.notifier);
    await actions.initialize();
  });
  tearDown(() async {
    container.dispose();
    await service.updates.close();
  });
  GpsPoint point({double accuracy = 5}) =>
      GpsPoint(35.2, -80.8, accuracy, DateTime.now());

  test('opted-in route survives app backgrounding and explicit stop saves it',
      () async {
    await actions.start(background: true);
    service.updates.add(point());
    await actions.background();
    expect(service.backgroundEnabled, isTrue);
    expect(container.read(mappingProvider).recording, isTrue);
    expect(service.updates.hasListener, isTrue);
    service.updates.add(GpsPoint(
        35.21, -80.81, 5, DateTime.now().add(const Duration(seconds: 1))));
    await actions.stop();
    expect(decodeSessions(service.stored).single.points.length, 2);
    expect(service.updates.hasListener, isFalse);
  });
  test('start requests location only on action and saves a real GPS session',
      () async {
    expect(service.authorizations, 0);
    await actions.start();
    service.updates.add(point());
    await actions.stop();
    final saved = decodeSessions(service.stored);
    expect(saved.single.points.length, 1);
    expect(saved.single.points.single.latitude, 35.2);
    expect(container.read(mappingProvider).recording, false);
    expect(service.updates.hasListener, false);
    final reopened = ProviderContainer(
        overrides: [mappingServiceProvider.overrideWithValue(service)]);
    await reopened.read(mappingProvider.notifier).initialize();
    expect(reopened.read(mappingProvider).sessions.single.id, saved.single.id);
    reopened.dispose();
  });
  test('rename saves atomically and storage failure retains the old name',
      () async {
    await actions.start();
    service.updates.add(point());
    await actions.stop();
    final session = container.read(mappingProvider).sessions.single;
    await actions.rename(session, '  Ridge walk  ');
    expect(decodeSessions(service.stored).single.name, 'Ridge walk');
    service.saveFails = true;
    await actions.rename(
        container.read(mappingProvider).sessions.single, 'Changed');
    expect(container.read(mappingProvider).sessions.single.name, 'Ridge walk');
  });
  test('permission denial leaves recording off', () async {
    service.denied = true;
    await actions.start();
    expect(container.read(mappingProvider).recording, false);
    expect(service.updates.hasListener, false);
    expect(
        container.read(mappingProvider).message, contains('Permission denied'));
  });
  test(
      'invalid inaccurate and stale fixes are ignored; empty route is not saved',
      () async {
    await actions.start();
    service.updates.add(point(accuracy: 500));
    service.updates.add(GpsPoint(91, 0, 5, DateTime.now()));
    service.updates.add(GpsPoint(
        35, -80, 5, DateTime.now().subtract(const Duration(minutes: 1))));
    await actions.stop();
    expect(service.stored, isNull);
    expect(container.read(mappingProvider).sessions, isEmpty);
  });
  test('background saves points and cancels GPS stream', () async {
    await actions.start();
    service.updates.add(point());
    await actions.background();
    expect(service.updates.hasListener, false);
    expect(decodeSessions(service.stored).single.points.length, 1);
  });
  test('background invalidates pending start', () async {
    service.permissionGate = Completer<void>();
    final start = actions.start();
    await actions.background();
    service.permissionGate!.complete();
    await start;
    expect(container.read(mappingProvider).recording, false);
    expect(service.updates.hasListener, false);
  });
  test('failed save retains route for retry and blocks destructive new start',
      () async {
    await actions.start();
    service.updates.add(point());
    service.saveFails = true;
    await actions.stop();
    expect(container.read(mappingProvider).points.length, 1);
    await actions.start();
    expect(container.read(mappingProvider).points.length, 1);
    service.saveFails = false;
    await actions.stop();
    expect(decodeSessions(service.stored).single.points.length, 1);
    expect(container.read(mappingProvider).points, isEmpty);
  });
  test('delete persists and clears selected route', () async {
    await actions.start();
    service.updates.add(point());
    await actions.stop();
    final session = container.read(mappingProvider).sessions.single;
    await actions.delete(session);
    expect(decodeSessions(service.stored), isEmpty);
    expect(container.read(mappingProvider).selected, isNull);
  });
}
