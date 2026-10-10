import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../radio/radio_notifier.dart';
import '../mapping/mapping_notifier.dart';
import '../radio/radio_screen.dart';

enum ScoutTab { map, radios, nodes, coverage, history, settings }

class MeshScoutShell extends ConsumerStatefulWidget {
  const MeshScoutShell({super.key, this.mapContent});
  final Widget? mapContent;

  @override
  ConsumerState<MeshScoutShell> createState() => _MeshScoutShellState();
}

class _MeshScoutShellState extends ConsumerState<MeshScoutShell>
    with WidgetsBindingObserver {
  ScoutTab _tab = ScoutTab.map;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future<void>.microtask(() {
      if (mounted) unawaited(ref.read(mappingProvider.notifier).initialize());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(ref.read(radioProvider.notifier).background());
      unawaited(ref.read(mappingProvider.notifier).background());
    } else if (state == AppLifecycleState.detached) {
      unawaited(ref.read(radioProvider.notifier).disconnect());
      unawaited(ref.read(mappingProvider.notifier).background());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _select(int index) {
    final next = ScoutTab.values[index];
    if (next == _tab) return;
    if (_tab == ScoutTab.radios) {
      final phase = ref.read(radioProvider).phase;
      final actions = ref.read(radioProvider.notifier);
      if (phase == RadioPhase.scanning) {
        unawaited(actions.stopScan());
      } else if (phase == RadioPhase.authorizing ||
          phase == RadioPhase.connecting ||
          phase == RadioPhase.identifying) {
        unawaited(actions.disconnect());
      }
    }
    setState(() => _tab = next);
  }

  @override
  Widget build(BuildContext context) {
    final radio = ref.watch(radioProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshScout'),
        actions: [
          IconButton(
            tooltip: 'Radio connection',
            onPressed: () => _select(ScoutTab.radios.index),
            icon: const Icon(Icons.bluetooth),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            RadioStatusBar(state: radio, onTap: () => _select(1)),
            Expanded(
              child: IndexedStack(
                index: _tab.index,
                children: [
                  MapScreen(mapContent: widget.mapContent),
                  const RadioScreen(embedded: true),
                  const FeaturePlaceholder(
                    icon: Icons.hub_outlined,
                    title: 'Nodes',
                    message: 'Node discovery is coming soon',
                    detail: 'MeshCore contacts and repeater discovery are not '
                        'implemented yet. Connecting a radio will not populate '
                        'this list in version 0.2.',
                  ),
                  const CoverageScreen(),
                  HistoryScreen(onMap: () => _select(0)),
                  SettingsScreen(onRadios: () => _select(1)),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab.index,
        onDestinationSelected: _select,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(
          Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10),
        ),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
          NavigationDestination(icon: Icon(Icons.bluetooth), label: 'Radios'),
          NavigationDestination(icon: Icon(Icons.hub_outlined), label: 'Nodes'),
          NavigationDestination(
              icon: Icon(Icons.layers_outlined), label: 'Coverage'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}

class RadioStatusBar extends StatelessWidget {
  const RadioStatusBar({super.key, required this.state, required this.onTap});
  final RadioState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = switch (state.phase) {
      RadioPhase.idle => 'Radio disconnected',
      RadioPhase.authorizing => 'Checking Bluetooth permissions…',
      RadioPhase.scanning => 'Scanning for radios…',
      RadioPhase.connecting => 'Connecting radio…',
      RadioPhase.identifying => 'Checking MeshCore compatibility…',
      RadioPhase.ready => 'MeshCore companion connected',
      RadioPhase.failed => 'Radio unavailable · tap to retry',
    };
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: ListTile(
        dense: true,
        leading: Icon(state.phase == RadioPhase.ready
            ? Icons.bluetooth_connected
            : Icons.bluetooth),
        title: Text(status),
        subtitle: state.phase == RadioPhase.ready
            ? const Text('Bluetooth connected · coverage recording unavailable')
            : null,
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key, this.mapContent});
  final Widget? mapContent;
  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _controller = MapController();
  bool _mapReady = false;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mapping = ref.watch(mappingProvider);
    ref.listen(mappingProvider, (previous, next) {
      if (!_mapReady || next.displayedPoints.isEmpty) return;
      if (previous?.displayedPoints == next.displayedPoints) return;
      final point = next.displayedPoints.last;
      _controller.move(LatLng(point.latitude, point.longitude), 16);
    });
    final points = mapping.displayedPoints;
    return Column(children: [
      const MappingAvailability(),
      Expanded(
          child: widget.mapContent ??
              FlutterMap(
                mapController: _controller,
                options: MapOptions(
                    initialCenter: const LatLng(39.8283, -98.5795),
                    initialZoom: 4,
                    onMapReady: () => _mapReady = true),
                children: [
                  TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'org.meshscout.mesh_scout'),
                  if (points.length > 1)
                    PolylineLayer(polylines: [
                      Polyline(
                          points: points
                              .map((p) => LatLng(p.latitude, p.longitude))
                              .toList(),
                          strokeWidth: 4,
                          color: Theme.of(context).colorScheme.primary)
                    ]),
                  if (points.isNotEmpty)
                    MarkerLayer(markers: [
                      Marker(
                          point: LatLng(
                              points.last.latitude, points.last.longitude),
                          child: const Icon(Icons.my_location,
                              color: Colors.blue, size: 30))
                    ]),
                  const RichAttributionWidget(attributions: [
                    TextSourceAttribution('OpenStreetMap contributors')
                  ]),
                ],
              )),
    ]);
  }
}

class MappingAvailability extends ConsumerWidget {
  const MappingAvailability({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mappingProvider);
    final actions = ref.read(mappingProvider.notifier);
    final retry = !state.recording && state.points.isNotEmpty;
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: state.loading || state.busy
                  ? null
                  : () async {
                      if (state.recording || retry) {
                        await actions.stop();
                      } else {
                        await actions.start();
                      }
                    },
              icon: Icon(state.recording ? Icons.stop : Icons.play_arrow),
              label: Text(state.busy
                  ? 'Please wait…'
                  : state.recording
                      ? 'Stop and save route'
                      : retry
                          ? 'Retry save'
                          : 'Start Mapping'),
            ),
            const SizedBox(height: 6),
            Text(
                state.recording
                    ? '${state.points.length} GPS points · recording route'
                    : 'GPS routes save on this phone. LoRa coverage is not recorded.',
                style: Theme.of(context).textTheme.bodySmall),
            if (state.message != null) Text(state.message!),
          ],
        ));
  }
}

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key, required this.onMap});
  final VoidCallback onMap;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(mappingProvider);
    final actions = ref.read(mappingProvider.notifier);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('History', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      const Text('Saved GPS routes · stored only on this phone'),
      if (state.loading) const LinearProgressIndicator(),
      if (!state.loading && state.sessions.isEmpty)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child:
                Text('No mapping sessions yet. Start Mapping on the Map tab.')),
      if (state.message != null) Text(state.message!),
      for (final session in state.sessions)
        ListTile(
          leading: const Icon(Icons.route),
          title: Text(session.started.toLocal().toString().split('.').first),
          subtitle: Text('${session.points.length} GPS points · '
              '${session.ended.difference(session.started).inMinutes} min'),
          onTap: state.recording || state.busy || state.points.isNotEmpty
              ? null
              : () {
                  actions.select(session);
                  onMap();
                },
          trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete session',
              onPressed:
                  state.recording || state.busy || state.points.isNotEmpty
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                      title: const Text('Delete this route?'),
                                      content: const Text(
                                          'This removes the saved GPS route from this phone.'),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('Cancel')),
                                        FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text('Delete'))
                                      ]));
                          if (confirmed == true) await actions.delete(session);
                        }),
        ),
    ]);
  }
}

class FeaturePlaceholder extends StatelessWidget {
  const FeaturePlaceholder({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String message;
  final String detail;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 32),
          Icon(icon, size: 48),
          const SizedBox(height: 16),
          Text(message, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(detail),
        ],
      );
}

class CoverageScreen extends StatelessWidget {
  const CoverageScreen({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Coverage', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 24),
          const Icon(Icons.layers_outlined, size: 48),
          const SizedBox(height: 16),
          Text('No coverage observations yet',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
              'GPS route recording is available on Map. LoRa observations and '
              'coverage overlays are not implemented. Bluetooth signal strength is only the '
              'phone-to-radio link; it is not LoRa coverage.'),
          const MappingAvailability(),
        ],
      );
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key, required this.onRadios});
  final VoidCallback onRadios;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: const Text('Bluetooth radios'),
            subtitle:
                const Text('Scan, connect, or disconnect a MeshCore companion'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onRadios,
          ),
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('App permissions'),
            subtitle: const Text('Manage Bluetooth access in Android settings'),
            onTap: () async => ref.read(radioProvider.notifier).openSettings(),
          ),
          const ListTile(
            leading: Icon(Icons.location_off_outlined),
            title: Text('GPS route recording'),
            subtitle: Text(
                'Precise location is requested when you start a route. '
                'Routes save on this phone; recording stops when you leave the app.'),
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('Privacy'),
            subtitle: Text(
                'GPS routes stay on this phone. No LoRa coverage or sharing. Online map tiles '
                'are requested from OpenStreetMap when the map is displayed.'),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('MeshScout 0.2.1'),
            subtitle:
                Text('Radio connections stay active while switching apps. '
                    'Android may still end them if the process is stopped.'),
          ),
        ],
      );
}
