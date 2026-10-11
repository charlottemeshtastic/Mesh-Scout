import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_scout/features/export/session_export.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';
import 'package:mesh_scout/features/offline/offline_maps.dart';

void main() {
  final time = DateTime.utc(2026, 10, 10);
  final point = GpsPoint(35.2, -80.8, 5, time);
  final session = MappingSession(
    id: 'route',
    started: time,
    ended: time,
    points: [point],
    observations: [
      CoverageObservation(point: point, rssi: -101, snr: -2.25, time: time),
    ],
  );
  test('GeoJSON uses longitude/latitude, retains measurements and avoids one-point lines', () {
    final json = jsonDecode(
      exportSession(session, ExportFormat.geoJson),
    ) as Map<String, dynamic>;
    final features = json['features'] as List<dynamic>;
    expect(features.length, 2);
    expect(features[0]['geometry']['coordinates'], [-80.8, 35.2]);
    expect(features[1]['properties']['rssi_dbm'], -101);
    expect(features[1]['properties']['snr_db'], -2.25);
    expect(features[1]['properties']['gps_time_utc'], time.toIso8601String());
  });
  test('CSV contains distinct GPS and raw reception rows with UTC times', () {
    final csv = exportSession(session, ExportFormat.csv);
    expect(csv.split('\r\n').length, 3);
    expect(csv, contains('"raw_lora_rx"'));
    expect(csv, contains('"-101","-2.25"'));
    expect(csv, contains(time.toIso8601String()));
  });
  test(
    'empty session exports valid empty GeoJSON; two points produce route',
    () {
      final empty = MappingSession(
        id: 'empty',
        started: time,
        ended: time,
        points: [],
      );
      expect(
        jsonDecode(exportSession(empty, ExportFormat.geoJson))['features'],
        isEmpty,
      );
      final route = MappingSession(
        id: 'two',
        started: time,
        ended: time,
        points: [point, GpsPoint(35.21, -80.81, 6, time)],
      );
      expect(
        jsonDecode(
          exportSession(route, ExportFormat.geoJson),
        )['features'][0]['geometry']['type'],
        'LineString',
      );
    },
  );
  test(
    'offline tile plan is bounded, unique and covers zoom 12 through 16',
    () {
      final tiles = areaTiles(35.2, -80.8);
      expect(tiles.length, lessThan(1000));
      expect(tiles.toSet().length, tiles.length);
      expect(tiles.map((t) => t.z).toSet(), {12, 13, 14, 15, 16});
      expect(() => areaTiles(0, 0), throwsFormatException);
      expect(() => areaTiles(double.nan, -80), throwsFormatException);
    },
  );
  test('complete download publishes only finished area and reloads without network', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meshscout-map-test',
    );
    final stale = File('${directory.path}/offline/pending/ghost.tile');
    await stale.parent.create(recursive: true);
    await stale.writeAsString('interrupted prior download');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.add([137, 80, 78, 71, 13, 10, 26, 10]);
      await request.response.close();
    });
    final container = ProviderContainer(
      overrides: [
        offlineDirectoryProvider.overrideWithValue(() async => directory.path),
        offlineThrottleProvider.overrideWithValue(Duration.zero),
        offlineTileUrlProvider.overrideWithValue(
          (tile) =>
              'http://127.0.0.1:${server.port}/${tile.z}/${tile.x}/${tile.y}',
        ),
      ],
    );
    try {
      final actions = container.read(offlineProvider.notifier);
      await actions.download(35.2, -80.8);
      final state = container.read(offlineProvider);
      expect(state.area, isNotNull);
      expect(state.area!.tiles, areaTiles(35.2, -80.8).length);
      expect(File('${state.area!.path}/ghost.tile').existsSync(), isFalse);
      expect(state.busy, isFalse);
      actions.enable(true);
      expect(container.read(offlineProvider).enabled, isTrue);
      await sub.cancel();
      await server.close(force: true);
      await actions.initialize();
      expect(container.read(offlineProvider).area!.tiles, state.area!.tiles);
      await actions.delete();
      expect(container.read(offlineProvider).area, isNull);
    } finally {
      container.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
  test(
    'separate named areas survive reload, selection and deletion of one area',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meshscout-multi-map',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add([137, 80, 78, 71, 13, 10, 26, 10]);
        await request.response.close();
      });
      final container = ProviderContainer(
        overrides: [
          offlineDirectoryProvider.overrideWithValue(
            () async => directory.path,
          ),
          offlineThrottleProvider.overrideWithValue(Duration.zero),
          offlineTileUrlProvider.overrideWithValue(
            (tile) => 'http://127.0.0.1:${server.port}/tile',
          ),
        ],
      );
      try {
        final actions = container.read(offlineProvider.notifier);
        await actions.download(35.2, -80.8, name: 'Home');
        await actions.download(35.3, -80.9, name: 'Trail');
        expect(container.read(offlineProvider).areas.length, 2);
        await actions.initialize();
        final home = container
            .read(offlineProvider)
            .areas
            .firstWhere((a) => a.name == 'Home');
        actions.select(home);
        actions.enable(true);
        expect(container.read(offlineProvider).area!.name, 'Home');
        await actions.delete();
        expect(container.read(offlineProvider).areas.single.name, 'Trail');
        expect(File('${home.path}/area.json').existsSync(), isFalse);
        await actions.initialize();
        expect(container.read(offlineProvider).areas.single.name, 'Trail');
      } finally {
        container.dispose();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
  test('resume reuses completed tiles and rename persists', () async {
    final directory = await Directory.systemTemp.createTemp('meshscout-resume');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    var fail = true;
    server.listen((request) async {
      requests++;
      if (fail && requests == 2) {
        request.response.statusCode = 503;
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add([137, 80, 78, 71, 13, 10, 26, 10]);
      }
      await request.response.close();
    });
    final container = ProviderContainer(
      overrides: [
        offlineDirectoryProvider.overrideWithValue(() async => directory.path),
        offlineThrottleProvider.overrideWithValue(Duration.zero),
        offlineTileUrlProvider.overrideWithValue(
          (tile) => 'http://127.0.0.1:${server.port}/tile',
        ),
      ],
    );
    try {
      final actions = container.read(offlineProvider.notifier);
      await actions.download(35.2, -80.8, name: 'Original');
      expect(container.read(offlineProvider).area, isNull);
      fail = false;
      await actions.resume();
      expect(requests, areaTiles(35.2, -80.8).length + 1);
      expect(container.read(offlineProvider).area!.name, 'Original');
      await actions.rename('Renamed');
      await actions.initialize();
      expect(container.read(offlineProvider).area!.name, 'Renamed');
      expect(
        File('${directory.path}/offline/pending/resume.json').existsSync(),
        isFalse,
      );
    } finally {
      container.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
  test('failed replacement preserves previous complete area', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meshscout-map-failure',
    );
    final active = Directory('${directory.path}/offline/active');
    await active.create(recursive: true);
    await File('${active.path}/area.json').writeAsString(
      jsonEncode({'lat': 35.2, 'lon': -80.8, 'tiles': 1, 'bytes': 8}),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 503;
      await request.response.close();
    });
    final container = ProviderContainer(
      overrides: [
        offlineDirectoryProvider.overrideWithValue(() async => directory.path),
        offlineTileUrlProvider.overrideWithValue(
          (tile) => 'http://127.0.0.1:${server.port}/tile',
        ),
      ],
    );
    try {
      final actions = container.read(offlineProvider.notifier);
      await actions.initialize();
      await actions.download(35.3, -80.9);
      expect(container.read(offlineProvider).area!.latitude, 35.2);
      expect(container.read(offlineProvider).message, contains('failed'));
      expect(File('${active.path}/area.json').existsSync(), isTrue);
      expect(
        File('${directory.path}/offline/pending/resume.json').existsSync(),
        isTrue,
      );
    } finally {
      container.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
  test('cancelled download publishes no partial area', () async {
    final directory = await Directory.systemTemp.createTemp(
      'meshscout-map-cancel',
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<void>();
    server.listen((request) {
      if (!received.isCompleted) received.complete();
    });
    final container = ProviderContainer(
      overrides: [
        offlineDirectoryProvider.overrideWithValue(() async => directory.path),
        offlineTileUrlProvider.overrideWithValue(
          (tile) => 'http://127.0.0.1:${server.port}/tile',
        ),
      ],
    );
    try {
      final actions = container.read(offlineProvider.notifier);
      final download = actions.download(35.2, -80.8);
      await received.future.timeout(const Duration(seconds: 5));
      actions.cancel();
      await download.timeout(const Duration(seconds: 5));
      expect(container.read(offlineProvider).busy, isFalse);
      expect(container.read(offlineProvider).area, isNull);
      expect(container.read(offlineProvider).message, contains('paused'));
      expect(
        Directory('${directory.path}/offline/active').existsSync(),
        isFalse,
      );
      expect(
        File('${directory.path}/offline/pending/resume.json').existsSync(),
        isTrue,
      );
    } finally {
      container.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    }
  });
  test(
    'interrupted replacement recovers its complete backup on startup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'meshscout-map-recovery',
      );
      final backup = Directory('${directory.path}/offline/backup');
      await backup.create(recursive: true);
      await File('${backup.path}/area.json').writeAsString(
        jsonEncode({'lat': 35.2, 'lon': -80.8, 'tiles': 1, 'bytes': 8}),
      );
      final container = ProviderContainer(
        overrides: [
          offlineDirectoryProvider.overrideWithValue(
            () async => directory.path,
          ),
        ],
      );
      try {
        await container.read(offlineProvider.notifier).initialize();
        expect(container.read(offlineProvider).area!.latitude, 35.2);
        expect(
          Directory('${directory.path}/offline/active').existsSync(),
          isTrue,
        );
        expect(backup.existsSync(), isFalse);
      } finally {
        container.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
