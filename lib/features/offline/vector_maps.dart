import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;

import 'offline_maps.dart';

/// Local files only: neither tile loading nor the bundled style uses a server.
class LocalVectorProvider extends vt.VectorTileProvider {
  LocalVectorProvider(this.area);
  final OfflineArea area;
  @override
  int get minimumZoom => area.minZoom;
  @override
  int get maximumZoom => area.maxZoom;
  @override
  String get cacheKey => 'meshscout:${area.path}';
  @override
  bool get cacheBytesToDisk => false;

  @override
  Future<vt.TileResponse> load(
    vt.TileKey tile, {
    vt.CancellationToken? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const vt.TileResponseCancelled();
    }
    if (tile.z < minimumZoom ||
        tile.z > maximumZoom ||
        !tile.isValid ||
        tile.x < 0 ||
        tile.x >= 1 << tile.z) {
      return const vt.TileResponseNotFound();
    }
    try {
      final file = File('${area.path}/${tile.z}/${tile.x}/${tile.y}.tile');
      if (!await file.exists()) return const vt.TileResponseNotFound();
      if (await file.length() > 4 * 1024 * 1024) {
        return vt.TileResponseError(const FormatException('Oversized tile'));
      }
      final bytes = await file.readAsBytes();
      if (cancellation?.isCancelled ?? false) {
        return const vt.TileResponseCancelled();
      }
      return vt.TileResponseData(bytes);
    } catch (error) {
      return vt.TileResponseError(error);
    }
  }
}

final scoutVectorTheme = vt.ThemeReader().read({
  'version': 8,
  'name': 'MeshScout offline basic',
  'layers': [
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': '#f2efe8'}
    },
    for (final layer in ['landcover', 'landuse', 'water', 'building'])
      {
        'id': layer,
        'type': 'fill',
        'source': 'local',
        'source-layer': layer,
        'paint': {
          'fill-color': switch (layer) {
            'water' => '#a8d3e6',
            'building' => '#c9bfb1',
            _ => '#d9e5cc',
          }
        },
      },
    for (final layer in ['waterway', 'transportation', 'boundary'])
      {
        'id': layer,
        'type': 'line',
        'source': 'local',
        'source-layer': layer,
        'paint': {
          'line-color': layer == 'waterway' ? '#87bdd5' : '#8b8278',
          'line-width': layer == 'transportation' ? 1.5 : 0.7,
        },
      },
    {
      'id': 'places',
      'type': 'symbol',
      'source': 'local',
      'source-layer': 'place',
      'layout': {
        'text-field': ['get', 'name'],
        'text-size': 12
      },
      'paint': {
        'text-color': '#283b44',
        'text-halo-color': '#ffffff',
        'text-halo-width': 1
      },
    },
  ],
});

class OfflineVectorLayer extends StatefulWidget {
  const OfflineVectorLayer({super.key, required this.area});
  final OfflineArea area;
  @override
  State<OfflineVectorLayer> createState() => _OfflineVectorLayerState();
}

class _OfflineVectorLayerState extends State<OfflineVectorLayer> {
  late final providers =
      vt.TileProviders({'local': LocalVectorProvider(widget.area)});
  @override
  void dispose() {
    providers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => vt.VectorTileLayer(
        theme: scoutVectorTheme,
        tileProviders: providers,
        tileOffset: vt.TileOffset.none,
        diskCacheMaximumSizeInBytes: 0,
        memoryCacheMaxBytes: 16 * 1024 * 1024,
        rasterCacheMaxBytes: 32 * 1024 * 1024,
      );
}
