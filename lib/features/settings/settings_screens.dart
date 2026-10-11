import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../alerts/message_alerts.dart';
import '../backup/backup.dart';
import '../backup/full_backup.dart';
import '../backup/storage_controls.dart';
import '../mapping/mapping_notifier.dart';
import '../radio/radio_notifier.dart';
import '../shell/help_screen.dart';
import '../shell/quick_guide.dart';
import 'field_settings.dart';

/// A Settings entry that opens one folder of related settings.
class SettingsFolderTile extends StatelessWidget {
  const SettingsFolderTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: children,
          ),
        ),
      );
}

class RadioAlertSettingsPage extends ConsumerWidget {
  const RadioAlertSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final field = ref.watch(fieldSettingsProvider);
    final alerts = ref.watch(messageAlertsProvider);
    final preset = ref.watch(radioProvider.select((s) => s.preset));
    return _SettingsPage(
      title: 'Radio and alerts',
      children: [
        SwitchListTile(
          title: const Text('Automatic radio reconnect'),
          subtitle: const Text(
            'Retry the same identified radio up to five times after link loss. Manual disconnect stops retries.',
          ),
          value: ref.watch(radioProvider).autoReconnect,
          onChanged: (enabled) async =>
              ref.read(radioProvider.notifier).setAutoReconnect(enabled),
        ),
        SwitchListTile(
          title: const Text('Alert when the radio drops'),
          subtitle: const Text(
            'Sound a notification when a connected radio loses its Bluetooth link. Disconnecting yourself never alerts. Follows silent mode and Do Not Disturb.',
          ),
          value: field.disconnectAlert,
          onChanged: (v) => ref
              .read(fieldSettingsProvider.notifier)
              .update((s) => s.copyWith(disconnectAlert: v)),
        ),
        SwitchListTile(
          title: const Text('Background message alerts'),
          subtitle: const Text(
            'Notify when the connected radio reports waiting messages. Fetch them manually in Nodes → Messages.',
          ),
          value: alerts.enabled,
          onChanged: alerts.busy
              ? null
              : (enabled) async =>
                  ref.read(messageAlertsProvider.notifier).configure(enabled),
        ),
        if (alerts.notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(alerts.notice!),
          ),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('Connected radio preset'),
          subtitle: Text(
            preset?.label ??
                'Connect a radio to read its frequency, bandwidth, SF and CR.',
          ),
        ),
      ],
    );
  }
}

class RecordingSettingsPage extends ConsumerWidget {
  const RecordingSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final field = ref.watch(fieldSettingsProvider);
    final mapping = ref.watch(mappingProvider);
    final update = ref.read(fieldSettingsProvider.notifier).update;
    return _SettingsPage(
      title: 'Recording',
      children: [
        SwitchListTile(
          title: const Text('Keep GPS recording in background'),
          subtitle: const Text(
            'Applies to the next route. Start while the app is open, then lock the phone or switch apps. An ongoing notification marks recording. Stop and save in Map. Android may stop the process; checkpointed GPS points are recovered on reopening.',
          ),
          value: ref.watch(backgroundGpsProvider),
          onChanged: mapping.recording || mapping.busy
              ? null
              : (value) => ref.read(backgroundGpsProvider.notifier).set(value),
        ),
        SwitchListTile(
          title: const Text('Auto-stop when parked'),
          subtitle: Text(
            'Stop and save the route after ${field.parkedMinutes} minutes within 30 m of the same spot.',
          ),
          value: field.autoStopParked,
          onChanged: (v) => update((s) => s.copyWith(autoStopParked: v)),
        ),
        if (field.autoStopParked)
          ListTile(
            title: const Text('Parked for'),
            trailing: DropdownButton<int>(
              value: field.parkedMinutes,
              items: [
                for (final minutes in FieldSettings.parkedChoices)
                  DropdownMenuItem(value: minutes, child: Text('$minutes min')),
              ],
              onChanged: (v) {
                if (v != null) update((s) => s.copyWith(parkedMinutes: v));
              },
            ),
          ),
        SwitchListTile(
          title: const Text('Stop recording on a flight'),
          subtitle: const Text(
            'Ignore fixes above 6,000 m or faster than 250 km/h, and end the session after two in a row so airborne receptions do not mix with ground coverage.',
          ),
          value: field.aircraftGuard,
          onChanged: (v) => update((s) => s.copyWith(aircraftGuard: v)),
        ),
        const ListTile(
          leading: Icon(Icons.height),
          title: Text('Altitude'),
          subtitle: Text(
            'Each GPS point keeps altitude when the phone reports it. CSV and GeoJSON exports include altitude_m for later elevation and line-of-sight work.',
          ),
        ),
      ],
    );
  }
}

class MapSettingsPage extends ConsumerWidget {
  const MapSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final field = ref.watch(fieldSettingsProvider);
    final update = ref.read(fieldSettingsProvider.notifier).update;
    return _SettingsPage(
      title: 'Map',
      children: [
        SwitchListTile(
          title: const Text('Show all saved coverage'),
          subtitle: const Text(
            'Draw measured 0.001° cells from every saved session, coloured by the strongest reception.',
          ),
          value: field.allCoverage,
          onChanged: (v) => update((s) => s.copyWith(allCoverage: v)),
        ),
        SwitchListTile(
          title: const Text('Show only recent coverage'),
          subtitle: Text(
            'Hide cells last measured more than ${field.recentCoverageDays} days ago, so areas that need mapping again stand out.',
          ),
          value: field.recentCoverageOnly,
          onChanged: field.allCoverage
              ? (v) => update((s) => s.copyWith(recentCoverageOnly: v))
              : null,
        ),
        if (field.recentCoverageOnly)
          ListTile(
            title: const Text('Recent means'),
            trailing: DropdownButton<int>(
              value: field.recentCoverageDays,
              items: [
                for (final days in FieldSettings.recentChoices)
                  DropdownMenuItem(value: days, child: Text('$days days')),
              ],
              onChanged: (v) {
                if (v != null) {
                  update((s) => s.copyWith(recentCoverageDays: v));
                }
              },
            ),
          ),
        SwitchListTile(
          title: const Text('Match the connected radio preset'),
          subtitle: const Text(
            'Saved coverage and History show only sessions recorded on the connected radio\'s frequency, bandwidth, SF and CR. Older sessions without a preset are hidden while this is on.',
          ),
          value: field.matchPreset,
          onChanged: (v) => update((s) => s.copyWith(matchPreset: v)),
        ),
        SwitchListTile(
          title: const Text('Group nodes that share a location'),
          subtitle: const Text(
            'Nodes on the same rooftop collapse into one marker. Tap to zoom in; tap again to pick one.',
          ),
          value: field.groupNodes,
          onChanged: (v) => update((s) => s.copyWith(groupNodes: v)),
        ),
        const ListTile(
          leading: Icon(Icons.circle_outlined),
          title: Text('Node marker edges'),
          subtitle: Text(
            'Green: advertised in the last 24 hours · amber: last 7 days · grey: older or unknown.',
          ),
        ),
      ],
    );
  }
}

class BackupSettingsPage extends StatelessWidget {
  const BackupSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => const _SettingsPage(
        title: 'Backup and storage',
        children: [BackupControls(), FullBackupControls(), StorageControls()],
      );
}

class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => _SettingsPage(
        title: 'About and support',
        children: [
          ListTile(
            leading: const Icon(Icons.auto_stories_outlined),
            title: const Text('Quick guide'),
            subtitle: const Text('The short tour shown on first launch'),
            onTap: () => unawaited(
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                    builder: (_) => const QuickGuideScreen()),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('Getting started and privacy'),
            subtitle: const Text(
              'Connect a radio, record a route and protect your data',
            ),
            onTap: () => unawaited(
              Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const HelpScreen()),
              ),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.location_off_outlined),
            title: Text('GPS route recording'),
            subtitle: Text(
              'Precise location is requested when you start a route. '
              'Routes save on this phone. Background recording is optional. Checkpointed routes recover after an interruption.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('Privacy'),
            subtitle: Text(
              'Saved sessions stay on this phone until you export/share them. Online map tiles '
              'use OpenStreetMap; offline downloads use USGS. Offline mode makes no tile requests.',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('MeshScout 1.3'),
            subtitle: Text(
              'Radio connections stay active while switching apps. '
              'Android may still end them if the process is stopped.',
            ),
          ),
        ],
      );
}
