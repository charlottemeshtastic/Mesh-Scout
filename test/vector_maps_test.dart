import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/offline/offline_maps.dart';
import 'package:mesh_scout/features/offline/vector_maps.dart';

void main() {
  test('legacy areas stay raster and vector loading is local and bounded',
      () async {
    final root = await Directory.systemTemp.createTemp('scout-vector');
    addTearDown(() => root.delete(recursive: true));
    expect(OfflineArea(root.path, 0, 0, 1, 10).isVector, false);
    final area = OfflineArea(root.path, 0, 0, 1, 10,
        kind: 'vector', minZoom: 0, maxZoom: 2);
    final provider = LocalVectorProvider(area);
    expect(provider.cacheBytesToDisk, false);
    expect(await provider.load(const vt.TileKey(1, 0, 0)),
        isA<vt.TileResponseNotFound>());
    final file = File('${root.path}/1/0/0.tile');
    await file.parent.create(recursive: true);
    final bytes =
        Uint8List.fromList([26, 9, 10, 5, 119, 97, 116, 101, 114, 120, 2]);
    await file.writeAsBytes(bytes);
    final loaded = await provider.load(const vt.TileKey(1, 0, 0));
    expect((loaded as vt.TileResponseData).bytes, bytes);
    expect(await provider.load(const vt.TileKey(1, -1, 0)),
        isA<vt.TileResponseNotFound>());
    final token = vt.CancellationToken()..cancel();
    expect(await provider.load(const vt.TileKey(1, 0, 0), cancellation: token),
        isA<vt.TileResponseCancelled>());
    await file.writeAsBytes(Uint8List(4 * 1024 * 1024 + 1));
    expect(await provider.load(const vt.TileKey(1, 0, 0)),
        isA<vt.TileResponseError>());
    expect(scoutVectorTheme.layers, isNotEmpty);
  });
  testWidgets('renders a local water polygon without a network basemap',
      (tester) async {
    final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('scout-vector-render')))!;
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/0/0/0.tile');
    await tester.runAsync(() async {
      await file.parent.create(recursive: true);
      await file.writeAsBytes([
        26,
        32,
        10,
        5,
        119,
        97,
        116,
        101,
        114,
        18,
        18,
        24,
        3,
        34,
        14,
        9,
        0,
        0,
        26,
        128,
        64,
        0,
        0,
        128,
        64,
        255,
        63,
        0,
        15,
        40,
        128,
        32,
        120,
        2
      ]);
    });
    const boundaryKey = ValueKey('vector-map');
    await tester.pumpWidget(MaterialApp(
        home: RepaintBoundary(
      key: boundaryKey,
      child: FlutterMap(options: const MapOptions(initialZoom: 0), children: [
        OfflineVectorLayer(
            area: OfflineArea(root.path, 0, 0, 1, 100,
                minZoom: 0, maxZoom: 0, kind: 'vector')),
      ]),
    )));
    var painted = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!painted && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(boundaryKey));
      final image = boundary.toImageSync();
      final data = await tester
          .runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba));
      final offset = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      painted = data != null &&
          data.getUint8(offset) == 168 &&
          data.getUint8(offset + 1) == 211 &&
          data.getUint8(offset + 2) == 230;
      image.dispose();
    }
    expect(painted, true,
        reason: 'local MVT geometry must paint, not just the background');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    vt.VectorTileLayer.clearMemoryCache();
  });
}
