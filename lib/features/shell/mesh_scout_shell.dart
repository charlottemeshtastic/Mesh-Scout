import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../radio/radio_notifier.dart';
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
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The app owns a foreground connection even when the Radios tab is hidden.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(radioProvider.notifier).disconnect());
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
                  const FeaturePlaceholder(
                    icon: Icons.history,
                    title: 'History',
                    message: 'No mapping sessions yet',
                    detail: 'Recording and saved sessions are coming soon. '
                        'Version 0.2 does not collect or save coverage data.',
                  ),
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
          NavigationDestination(icon: Icon(Icons.layers_outlined), label: 'Coverage'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
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

class MapScreen extends StatelessWidget {
  const MapScreen({super.key, this.mapContent});
  final Widget? mapContent;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const MappingAvailability(),
      Expanded(
        child: mapContent ?? FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(39.8283, -98.5795),
            initialZoom: 4,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'org.meshscout.mesh_scout',
            ),
            const RichAttributionWidget(
              attributions: [TextSourceAttribution('OpenStreetMap contributors')],
            ),
          ],
        ),
      ),
    ],
  );
}

class MappingAvailability extends StatelessWidget {
  const MappingAvailability({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Start Mapping'),
        ),
        const SizedBox(height: 8),
        Text(
          'Coming soon — GPS and coverage recording are not available yet.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
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
      const Text('GPS capture, LoRa signal observations, and coverage overlays '
          'are coming soon. Bluetooth signal strength is only the '
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
        subtitle: const Text('Scan, connect, or disconnect a MeshCore companion'),
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
        title: Text('GPS and recording · coming soon'),
        subtitle: Text('No GPS capture, background tracking, or saved sessions. '
            'Older Android requires location permission for Bluetooth scanning.'),
      ),
      const ListTile(
        leading: Icon(Icons.privacy_tip_outlined),
        title: Text('Privacy'),
        subtitle: Text('No coverage collection or sharing. Online map tiles '
            'are requested from OpenStreetMap when the map is displayed.'),
      ),
      const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('MeshScout 0.2'),
        subtitle: Text('Independent MeshCore app. Bluetooth requires testing '
            'on your Android phone and companion radio.'),
      ),
    ],
  );
}
