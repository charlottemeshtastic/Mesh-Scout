import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'features/radio/radio_notifier.dart';
import 'features/radio/radio_screen.dart';
import 'native/android_ble_service.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

void main() => runApp(ProviderScope(
  overrides: [bleServiceProvider.overrideWithValue(AndroidBleService(FlutterReactiveBle()))],
  child: const MeshScoutApp(),
));

class MeshScoutApp extends StatelessWidget {
  const MeshScoutApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MeshScout',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('MeshScout'), actions: [
        Builder(builder: (context) => IconButton(
          tooltip: 'Connect MeshCore radio', icon: const Icon(Icons.bluetooth),
          onPressed: () async { await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RadioScreen())); },
        )),
      ]),
      body: FlutterMap(
        options: const MapOptions(initialCenter: LatLng(39.8283, -98.5795), initialZoom: 4),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'org.meshscout.app'),
          const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
        ],
      ),
    ),
  );
}
