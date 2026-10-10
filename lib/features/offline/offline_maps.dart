import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef MapTile = ({int z, int x, int y});
List<MapTile> areaTiles(double latitude, double longitude, {int sideKm = 4}) {
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude < 24 ||
      latitude > 50 ||
      longitude < -125 ||
      longitude > -66) {
    throw const FormatException(
        'Offline topo currently supports the contiguous U.S.');
  }
  if (![4, 8, 12].contains(sideKm)) {
    throw const FormatException('Choose a 4, 8 or 12 km area.');
  }
  final latDelta = sideKm / 2 / 111.32;
  final lonDelta = latDelta / math.cos(latitude * math.pi / 180);
  int x(double lon, int n) => ((lon + 180) / 360 * n).floor();
  int y(double lat, int n) {
    final radians = lat * math.pi / 180;
    return ((1 -
                math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) /
            2 *
            n)
        .floor();
  }

  final tiles = <MapTile>[];
  for (var z = 12; z <= 16; z++) {
    final n = 1 << z;
    for (var col = x(longitude - lonDelta, n);
        col <= x(longitude + lonDelta, n);
        col++) {
      for (var row = y(latitude + latDelta, n);
          row <= y(latitude - latDelta, n);
          row++) {
        tiles.add((z: z, x: col, y: row));
      }
    }
  }
  if (tiles.length > 5000) {
    throw const FormatException('Area exceeds the download limit.');
  }
  return tiles;
}

class OfflineArea {
  const OfflineArea(
      this.path, this.latitude, this.longitude, this.tiles, this.bytes,
      {this.sideKm = 4, this.name});
  final String path;
  final String? name;
  final double latitude, longitude;
  final int tiles, bytes, sideKm;
}

final offlineDirectoryProvider = Provider<Future<String> Function()>((ref) =>
    () async => (await const MethodChannel('org.meshscout/files')
        .invokeMethod<String>('directory'))!);
final dataDirectoryProvider = Provider<Future<String> Function()>(
    (ref) => ref.read(offlineDirectoryProvider));
final offlineTileUrlProvider = Provider<
    String Function(
        MapTile)>((ref) => (tile) =>
    'https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/${tile.z}/${tile.y}/${tile.x}');
final offlineThrottleProvider =
    Provider<Duration>((ref) => const Duration(milliseconds: 100));
final offlineProvider =
    NotifierProvider<OfflineMaps, OfflineState>(OfflineMaps.new);

class OfflineState {
  const OfflineState(
      {this.area,
      this.areas = const [],
      this.busy = false,
      this.progress = 0,
      this.total = 0,
      this.enabled = false,
      this.message});
  final OfflineArea? area;
  final List<OfflineArea> areas;
  final bool busy, enabled;
  final int progress, total;
  final String? message;
}

class OfflineMaps extends Notifier<OfflineState> {
  HttpClient? _client;
  int _generation = 0;
  bool _running = false;
  bool _committing = false;
  @override
  OfflineState build() {
    ref.onDispose(() {
      _generation++;
      _client?.close(force: true);
    });
    return const OfflineState();
  }

  Future<Directory> _root() async =>
      Directory('${await ref.read(offlineDirectoryProvider)()}/offline');
  Future<void> initialize() async {
    try {
      final root = await _root();
      final active = Directory('${root.path}/active');
      final backup = Directory('${root.path}/backup');
      if (!active.existsSync() && backup.existsSync()) {
        await backup.rename(active.path);
      }
      if (active.existsSync() && backup.existsSync()) {
        await backup.delete(recursive: true);
      }
      final areas = <OfflineArea>[];
      if (root.existsSync()) {
        for (final entry in root.listSync().whereType<Directory>()) {
          if (entry.path.endsWith('/pending') || entry.path.endsWith('/backup')) {
            continue;
          }
          final metadata = File('${entry.path}/area.json');
          if (!metadata.existsSync()) continue;
          final data =
              jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
          areas.add(OfflineArea(
              entry.path,
              (data['lat'] as num).toDouble(),
              (data['lon'] as num).toDouble(),
              data['tiles'] as int,
              data['bytes'] as int,
              sideKm: data['sideKm'] as int? ?? 4,
              name: data['name'] as String?));
        }
      }
      areas.sort((a, b) => b.path.compareTo(a.path));
      if (!ref.mounted) return;
      state = OfflineState(
          area: areas.isEmpty ? null : areas.first,
          areas: List.unmodifiable(areas));
    } catch (_) {
      if (!ref.mounted) return;
      state = const OfflineState(
          message: 'Could not load offline area. Download again.');
    }
  }

  void enable(bool value) {
    state = OfflineState(
        area: state.area,
        areas: state.areas,
        enabled: value && state.area != null,
        message: state.message);
  }

  void cancel() {
    if (_committing) return;
    _generation++;
    _client?.close(force: true);
    state = OfflineState(
        area: state.area,
        areas: state.areas,
        enabled: state.enabled,
        message: 'Download cancelled; previous area retained.');
  }

  Future<void> download(double lat, double lon,
      {int sideKm = 4, String? name}) async {
    if (_running || state.busy) return;
    _running = true;
    final generation = ++_generation;
    final previous = state.area;
    final saved = state.areas;
    Directory? staging;
    try {
      if (saved.length >= 5) {
        throw const FormatException(
            'Keep up to five offline areas. Delete one first.');
      }
      if (name != null &&
          (name.trim().length > 60 || name.contains(RegExp(r'[\x00-\x1f]')))) {
        throw const FormatException('Use a name of up to 60 characters.');
      }
      final tiles = areaTiles(lat, lon, sideKm: sideKm);
      state = OfflineState(
          area: previous, areas: saved, busy: true, total: tiles.length);
      final root = await _root();
      if (generation != _generation) return;
      await root.create(recursive: true);
      staging = Directory('${root.path}/pending');
      if (staging.existsSync()) await staging.delete(recursive: true);
      await staging.create(recursive: true);
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      _client = client;
      var bytes = 0;
      var count = 0;
      for (final tile in tiles) {
        if (generation != _generation) return;
        final request = await client
            .getUrl(Uri.parse(ref.read(offlineTileUrlProvider)(tile)))
            .timeout(const Duration(seconds: 20));
        request.headers.set(
            'User-Agent', 'MeshScout/0.9 (independent Android mapping app)');
        final response =
            await request.close().timeout(const Duration(seconds: 20));
        if (response.statusCode != 200 ||
            !(response.headers.contentType?.mimeType.startsWith('image/') ??
                false)) {
          throw const FormatException(
              'Map service did not return an image. Try later.');
        }
        final data = <int>[];
        await for (final chunk
            in response.timeout(const Duration(seconds: 20))) {
          data.addAll(chunk);
          if (data.length > 1024 * 1024 ||
              bytes + data.length > 150 * 1024 * 1024) {
            throw const FormatException('Download exceeded 150 MB limit.');
          }
        }
        if (data.length < 8 ||
            !(data[0] == 137 && data[1] == 80 ||
                data[0] == 255 && data[1] == 216)) {
          throw const FormatException('Invalid map image.');
        }
        final file = File('${staging.path}/${tile.z}/${tile.x}/${tile.y}.tile');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data, flush: true);
        bytes += data.length;
        count++;
        if (generation != _generation) return;
        state = OfflineState(
            area: previous,
            areas: saved,
            busy: true,
            progress: count,
            total: tiles.length);
        await Future<void>.delayed(ref.read(offlineThrottleProvider));
      }
      await File('${staging.path}/area.json').writeAsString(
          jsonEncode({
            'lat': lat,
            'lon': lon,
            'tiles': count,
            'bytes': bytes,
            'sideKm': sideKm,
            if (name != null && name.trim().isNotEmpty) 'name': name.trim()
          }),
          flush: true);
      if (generation != _generation) return;
      _committing = true;
      final active = Directory(
          '${root.path}/area-${DateTime.now().microsecondsSinceEpoch}');
      await staging.rename(active.path);
      if (!ref.mounted) return;
      final area = OfflineArea(active.path, lat, lon, count, bytes,
          sideKm: sideKm, name: name?.trim());
      state = OfflineState(
          area: area,
          areas: List.unmodifiable([area, ...saved]),
          message: 'Area saved. Select an area and enable Offline map.');
    } catch (e) {
      if (ref.mounted && generation == _generation) {
        state = OfflineState(
            area: previous, areas: saved, message: 'Download failed: $e');
      }
    } finally {
      _running = false;
      _committing = false;
      _client?.close(force: true);
      _client = null;
      if (staging != null && staging.existsSync()) {
        await staging.delete(recursive: true);
      }
    }
  }

  void select(OfflineArea area) {
    if (_running || state.busy || !state.areas.contains(area)) return;
    state =
        OfflineState(area: area, areas: state.areas, enabled: state.enabled);
  }

  Future<void> delete() async {
    if (_running || state.busy || state.area == null) return;
    final selected = state.area!;
    final directory = Directory(selected.path);
    if (directory.existsSync()) await directory.delete(recursive: true);
    final areas = state.areas.where((a) => a.path != selected.path).toList();
    state = OfflineState(
        area: areas.isEmpty ? null : areas.first,
        areas: List.unmodifiable(areas),
        enabled: state.enabled && areas.isNotEmpty,
        message: 'Selected offline area deleted.');
  }
}
