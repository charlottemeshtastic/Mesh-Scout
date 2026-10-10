import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef MapTile = ({int z, int x, int y});
List<MapTile> areaTiles(double latitude, double longitude) {
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude < 24 ||
      latitude > 50 ||
      longitude < -125 ||
      longitude > -66) {
    throw const FormatException(
        'Offline topo currently supports the contiguous U.S.');
  }
  final latDelta = 2 / 111.32;
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
  if (tiles.length > 1000)
    throw const FormatException('Area exceeds the download limit.');
  return tiles;
}

class OfflineArea {
  const OfflineArea(
      this.path, this.latitude, this.longitude, this.tiles, this.bytes);
  final String path;
  final double latitude, longitude;
  final int tiles, bytes;
}

final offlineDirectoryProvider = Provider<Future<String> Function()>((ref) =>
    () async => (await const MethodChannel('org.meshscout/files')
        .invokeMethod<String>('directory'))!);
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
      this.busy = false,
      this.progress = 0,
      this.total = 0,
      this.enabled = false,
      this.message});
  final OfflineArea? area;
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
      if (!active.existsSync() && backup.existsSync())
        await backup.rename(active.path);
      final metadata = File('${root.path}/active/area.json');
      if (!metadata.existsSync()) return;
      final data =
          jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
      if (!ref.mounted) return;
      state = OfflineState(
          area: OfflineArea(
              '${root.path}/active',
              (data['lat'] as num).toDouble(),
              (data['lon'] as num).toDouble(),
              data['tiles'] as int,
              data['bytes'] as int));
    } catch (_) {
      if (!ref.mounted) return;
      state = const OfflineState(
          message: 'Could not load offline area. Download again.');
    }
  }

  void enable(bool value) {
    state = OfflineState(
        area: state.area,
        enabled: value && state.area != null,
        message: state.message);
  }

  void cancel() {
    if (_committing) return;
    _generation++;
    _client?.close(force: true);
    state = OfflineState(
        area: state.area,
        enabled: state.enabled,
        message: 'Download cancelled; previous area retained.');
  }

  Future<void> download(double lat, double lon) async {
    if (_running || state.busy) return;
    _running = true;
    final generation = ++_generation;
    final previous = state.area;
    Directory? staging;
    try {
      final tiles = areaTiles(lat, lon);
      state = OfflineState(area: previous, busy: true, total: tiles.length);
      final root = await _root();
      if (generation != _generation) return;
      await root.create(recursive: true);
      staging = Directory('${root.path}/pending-$generation');
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
            'User-Agent', 'MeshScout/0.4 (independent Android mapping app)');
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
              bytes + data.length > 50 * 1024 * 1024) {
            throw const FormatException('Download exceeded 50 MB limit.');
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
            area: previous, busy: true, progress: count, total: tiles.length);
        await Future<void>.delayed(ref.read(offlineThrottleProvider));
      }
      await File('${staging.path}/area.json').writeAsString(
          jsonEncode({'lat': lat, 'lon': lon, 'tiles': count, 'bytes': bytes}),
          flush: true);
      if (generation != _generation) return;
      _committing = true;
      final active = Directory('${root.path}/active');
      final backup = Directory('${root.path}/backup');
      if (backup.existsSync()) await backup.delete(recursive: true);
      if (active.existsSync()) await active.rename(backup.path);
      try {
        await staging.rename(active.path);
      } catch (_) {
        if (backup.existsSync()) await backup.rename(active.path);
        rethrow;
      }
      if (!ref.mounted) return;
      state = OfflineState(
          area: OfflineArea(active.path, lat, lon, count, bytes),
          message:
              'Area saved. Enable Offline map to use it without internet.');
      try {
        if (backup.existsSync()) await backup.delete(recursive: true);
      } catch (_) {
        // The complete active area is already published; cleanup can wait.
      }
    } catch (e) {
      if (ref.mounted && generation == _generation) {
        state = OfflineState(area: previous, message: 'Download failed: $e');
      }
    } finally {
      _running = false;
      _committing = false;
      _client?.close(force: true);
      _client = null;
      if (staging != null && staging.existsSync())
        await staging.delete(recursive: true);
    }
  }

  Future<void> delete() async {
    if (_running || state.busy) return;
    final root = await _root();
    if (root.existsSync()) await root.delete(recursive: true);
    state = const OfflineState(message: 'Offline area deleted.');
  }
}
