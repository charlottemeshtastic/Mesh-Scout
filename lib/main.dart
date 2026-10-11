import 'package:flutter/material.dart';
import 'about_meshscout_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'features/radio/radio_notifier.dart';
import 'features/radio/radio_screen.dart';
import 'native/android_ble_service.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

void main() => runApp(ProviderScope(
      overrides: [bleServiceProvider.overrideWithValue(AndroidBleService())],
      child: const MeshScoutApp(),
    ));

class MeshScoutApp extends StatelessWidget {
  const MeshScoutApp({super.key});

  static const background = Color(0xFF101820);
  static const cyan = Color(0xFF00D9FF);
  static const steelBlue = Color(0xFF28465A);

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MeshScout',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: background,
          colorScheme: const ColorScheme.dark(
            primary: cyan,
            secondary: steelBlue,
            surface: background,
            onSurface: Color(0xFFE6EDF3),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: background,
            foregroundColor: cyan,
            centerTitle: false,
          ),
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('MeshScout'), actions: [
            IconButton(
              tooltip: 'About MeshScout',
              icon: const Icon(Icons.info_outline),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AboutMeshScoutScreen()),
              ),
            ),
            Builder(
                builder: (context) => IconButton(
                      tooltip: 'Connect MeshCore radio',
                      icon: const Icon(Icons.bluetooth),
                      onPressed: () async {
                        await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => const RadioScreen()));
                      },
                    )),
          ]),
          body: FlutterMap(
            options: const MapOptions(
                initialCenter: LatLng(39.8283, -98.5795), initialZoom: 4),
            children: [
              TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'org.meshscout.mesh_scout'),
              const RichAttributionWidget(attributions: [
                TextSourceAttribution('OpenStreetMap contributors')
              ]),
            ],
          ),
        ),
      );
}
