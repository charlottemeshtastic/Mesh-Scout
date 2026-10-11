import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/offline/offline_maps.dart';
import 'package:mesh_scout/features/offline/vector_maps.dart';

void main() {
  test('legacy areas stay raster and vector loading is local and bounded', () async {
    final root = await Directory.systemTemp.createTemp('scout-vector');
    addTearDown(() => root.delete(recursive: true));
    expect(OfflineArea(root.path, 0, 0, 1, 10).isVector, false);
    final area = OfflineArea(root.path, 0, 0, 1, 10,
        kind: 'vector', minZoom: 0, maxZoom: 2);
    final provider = LocalVectorProvider(area);
    expect(provider.cacheBytesToDisk, false);
    expect(await provider.load(const vt.TileKey(1, 0, 0)), isA<vt.TileResponseNotFound>());
    final file = File('${root.path}/1/0/0.tile');
    await file.parent.create(recursive: true);
    final bytes = Uint8List.fromList([26, 9, 10, 5, 119, 97, 116, 101, 114, 120, 2]);
    await file.writeAsBytes(bytes);
    final loaded = await provider.load(const vt.TileKey(1, 0, 0));
    expect((loaded as vt.TileResponseData).bytes, bytes);
    expect(await provider.load(const vt.TileKey(1, -1, 0)), isA<vt.TileResponseNotFound>());
    final token = vt.CancellationToken()..cancel();
    expect(await provider.load(const vt.TileKey(1, 0, 0), cancellation: token), isA<vt.TileResponseCancelled>());
    await file.writeAsBytes(Uint8List(4 * 1024 * 1024 + 1));
    expect(await provider.load(const vt.TileKey(1, 0, 0)), isA<vt.TileResponseError>());
    expect(scoutVectorTheme.layers, isNotEmpty);
  });
}
