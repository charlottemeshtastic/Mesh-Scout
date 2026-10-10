import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../radio/radio_notifier.dart';
import '../mapping/mapping_notifier.dart';
import '../radio/radio_screen.dart';
import '../nodes/nodes_screen.dart';
import '../export/session_export.dart';
import '../offline/offline_maps.dart';
import '../offline/offline_controls.dart';

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
      if (mounted) {
        unawaited(ref.read(mappingProvider.notifier).initialize());
        unawaited(ref.read(offlineProvider.notifier).initialize());
      }
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
    ref.listen(radioProvider, (previous, next) {
      if (next.lastRx != null && !identical(previous?.lastRx, next.lastRx)) {
        ref.read(mappingProvider.notifier).capture(next.lastRx!);
      }
    });
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
                  const NodesScreen(),
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
      RadioPhase.reconnecting =>
        'Reconnecting radio · attempt ${state.retryAttempt}/5',
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
            ? const Text(
                'Bluetooth connected · GPS-tagged LoRa reception available')
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
  bool _showNodes = true;
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
    final offline = ref.watch(offlineProvider);
    final nodes = ref
        .watch(radioProvider)
        .contacts
        .where((c) => c.latitude != null && c.longitude != null)
        .toList();
    final points = mapping.displayedPoints;
    final observations = mapping.displayedObservations;
    return Column(children: [
      const MappingAvailability(),
      OfflineControls(center: () {
        final center = _mapReady
            ? _controller.camera.center
            : const LatLng(39.8283, -98.5795);
        return (lat: center.latitude, lon: center.longitude);
      }),
      Row(children: [
        Checkbox(
            value: _showNodes,
            onChanged: (v) => setState(() => _showNodes = v ?? false)),
        Expanded(
            child: Text(
                'Advertised nodes: ${nodes.length} · locations may be stale',
                style: Theme.of(context).textTheme.bodySmall)),
      ]),
      Expanded(
          child: widget.mapContent ??
              FlutterMap(
                mapController: _controller,
                options: MapOptions(
                    initialCenter: const LatLng(39.8283, -98.5795),
                    initialZoom: 4,
                    onMapReady: () => _mapReady = true),
                children: [
                  if (offline.enabled)
                    TileLayer(
                      key: ValueKey(offline.area),
                      urlTemplate: '${offline.area!.path}/{z}/{x}/{y}.tile',
                      tileProvider: FileTileProvider(),
                      minNativeZoom: 12,
                      maxNativeZoom: 16,
                      errorTileCallback: (tile, error, stack) {},
                    )
                  else
                    TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'org.meshscout.mesh_scout'),
                  if (_showNodes)
                    MarkerLayer(markers: [
                      for (final node in nodes)
                        Marker(
                            width: 44,
                            height: 44,
                            point: LatLng(node.latitude!, node.longitude!),
                            child: IconButton(
                                tooltip:
                                    '${node.name.isEmpty ? "Unnamed node" : node.name} · advertised',
                                icon: Icon(
                                    node.type == 2
                                        ? Icons.cell_tower
                                        : Icons.person_pin_circle,
                                    color: Colors.purple),
                                onPressed: () => showDialog<void>(
                                    context: context,
                                    builder: (c) => AlertDialog(
                                            title: Text(node.name.isEmpty
                                                ? 'Unnamed node'
                                                : node.name),
                                            content: Text(
                                                '${node.typeLabel}\nAdvertised location; current reachability unverified.\n${node.lastAdvert == null ? "No advertisement time" : node.lastAdvert!.toLocal()}\n${node.key}'),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(c),
                                                  child: const Text('Close'))
                                            ]))))
                    ]),
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
                  if (observations.isNotEmpty)
                    CircleLayer(circles: [
                      for (final observation in observations)
                        CircleMarker(
                            point: LatLng(observation.point.latitude,
                                observation.point.longitude),
                            radius: 6,
                            color: signalColor(observation.rssi)
                                .withValues(alpha: 0.7),
                            borderColor: Colors.white,
                            borderStrokeWidth: 1),
                    ]),
                  const RichAttributionWidget(attributions: [
                    TextSourceAttribution(
                        'OpenStreetMap contributors · Offline: USGS National Geospatial Program')
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
                    ? '${state.points.length} GPS points · ${state.observations.length} LoRa observations'
                    : 'GPS routes and received LoRa observations save on this phone.',
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
          subtitle: Text(
              '${session.points.length} GPS points · ${session.observations.length} LoRa observations · '
              '${session.ended.difference(session.started).inMinutes} min'),
          onTap: state.recording || state.busy || state.points.isNotEmpty
              ? null
              : () {
                  actions.select(session);
                  onMap();
                },
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: 'Export session',
                onPressed: () async {
                  final choice =
                      await showDialog<({ExportFormat format, bool share})>(
                          context: context,
                          builder: (c) => SimpleDialog(
                                  title: const Text('Export session'),
                                  children: [
                                    const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Text(
                                            'Export includes precise route locations and reception times. Choose where to save or share it.')),
                                    for (final format in ExportFormat.values)
                                      for (final share in [false, true])
                                        SimpleDialogOption(
                                            onPressed: () => Navigator.pop(c,
                                                (format: format, share: share)),
                                            child: Text(
                                                '${share ? "Share" : "Save"} ${format == ExportFormat.csv ? "CSV" : "GeoJSON"}'))
                                  ]));
                  if (choice == null) return;
                  try {
                    final done = await SessionExportService()
                        .send(session, choice.format, share: choice.share);
                    if (context.mounted)
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(done
                              ? choice.share
                                  ? 'Share menu opened'
                                  : 'Session saved'
                              : 'Save cancelled')));
                  } catch (_) {
                    if (context.mounted)
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content:
                              Text('Export failed. Try another destination.')));
                  }
                }),
            IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete session',
                onPressed: state.recording ||
                        state.busy ||
                        state.points.isNotEmpty
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
          ]),
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

Color signalColor(int rssi) => rssi >= -90
    ? Colors.green
    : rssi >= -110
        ? Colors.orange
        : Colors.red;

class CoverageScreen extends ConsumerWidget {
  const CoverageScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mapping = ref.watch(mappingProvider);
    final radio = ref.watch(radioProvider);
    final observations = mapping.displayedObservations;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Coverage', style: Theme.of(context).textTheme.headlineSmall),
      const Text(
          'Received LoRa signal observations at your GPS location. These are last-hop reception metrics, not proof of sender reachability or two-way coverage.'),
      const SizedBox(height: 12),
      Text('${observations.length} GPS-tagged LoRa observations'),
      const Text(
          'Map dots: green ≥ −90 dBm · orange ≥ −110 dBm · red below −110 dBm. No interpolation between points.'),
      if (radio.lastRx != null)
        Text(
            'Latest reception: ${radio.lastRx!.rssi} dBm · SNR ${radio.lastRx!.snr.toStringAsFixed(2)} dB'),
      if (radio.phase != RadioPhase.ready)
        const Text('Connect your companion radio to receive LoRa metrics.'),
      if (observations.isEmpty)
        const Text(
            'No coverage observations yet. Start Mapping outdoors while connected. Only received radio packets with a GPS fix from the last 15 seconds are recorded.'),
      const MappingAvailability(),
      for (final observation in observations.reversed.take(100))
        ListTile(
            leading: Icon(Icons.circle, color: signalColor(observation.rssi)),
            title: Text(
                '${observation.rssi} dBm · SNR ${observation.snr.toStringAsFixed(2)} dB'),
            subtitle: Text(
                '${observation.time.toLocal().toString().split('.').first} · GPS ±${observation.point.accuracy.round()} m')),
      if (observations.length > 100)
        const Text(
            'Latest 100 listed; the session and map contain all saved observations.'),
    ]);
  }
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
          SwitchListTile(
              title: const Text('Automatic radio reconnect'),
              subtitle: const Text(
                  'Retry the same identified radio up to five times after link loss. Manual disconnect stops retries.'),
              value: ref.watch(radioProvider).autoReconnect,
              onChanged: (enabled) async =>
                  ref.read(radioProvider.notifier).setAutoReconnect(enabled)),
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
                'Saved sessions stay on this phone until you export/share them. Online map tiles '
                'use OpenStreetMap; offline downloads use USGS. Offline mode makes no tile requests.'),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('MeshScout 0.4'),
            subtitle:
                Text('Radio connections stay active while switching apps. '
                    'Android may still end them if the process is stopped.'),
          ),
        ],
      );
}
