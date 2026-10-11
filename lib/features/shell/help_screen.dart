import 'package:flutter/material.dart';

/// Reopenable setup guidance without requesting permissions or changing settings.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Getting started and privacy')),
        body: ListView(padding: const EdgeInsets.all(16), children: const [
          _HelpSection('1. Connect your radio',
              'Use a MeshCore companion radio with Bluetooth enabled. Open Radios, tap Scan for radios, and select it as soon as it appears. Allow Bluetooth access when Android asks. Wait for MeshCore companion connected. Another app may already own the radio connection; close its connection first.'),
          _HelpSection('2. Record outdoors',
              'Open Map and tap Start Mapping. Allow precise location and wait for a GPS fix outdoors. Received LoRa packets are associated with a recent GPS fix. Tap Stop and save route when finished; reopen it from History.'),
          _HelpSection('3. Keep recording while switching apps',
              'Enable Keep GPS recording in background in Settings before starting the next route. An ongoing Android notification identifies recording. Keep Bluetooth and location enabled. Android battery restrictions can interrupt services. Reopen MeshScout to recover the latest saved checkpoint after an interruption.'),
          _HelpSection('4. Messages and contacts',
              'Open Nodes to refresh contacts and open Messages. Fetch the inbox manually or enable Automatic inbox retrieval. Sending always needs your action. Direct delivery requires an acknowledgement; channel acceptance does not confirm delivery to every node. Saved contacts may be stale.'),
          _HelpSection('5. Offline maps',
              'Save a USGS area within the contiguous United States, or import a licensed raster MBTiles pack. Select a saved area and enable offline mode before losing connectivity. Outside that area there is no basemap. Online OpenStreetMap tiles are not downloaded in bulk.'),
          _HelpSection('6. Back up before cleanup',
              'Disconnect the radio and stop recording/downloads before backup or restore. Full backup can include maps and encryption. Keep an encrypted backup and its passphrase somewhere safe. Restore offers a preview with Merge or Replace. Export includes exact route locations or private messages; choose destinations carefully.'),
          _HelpSection('Privacy and network access',
              'MeshScout stores routes, reception observations, contacts, messages, preferences and map packs in private app storage. It has no MeshScout account, advertising or analytics SDK. Online maps send tile requests and your network address to OpenStreetMap; requested tile coordinates reveal the viewed area. USGS receives offline download requests. Offline mode makes no basemap requests. Cloud backup uses a document provider you choose; that provider handles its account and network access. Bluetooth commands and messages go to your selected radio.'),
          _HelpSection('Permissions and deletion',
              'Bluetooth access supports discovery and connection. Precise location supports route recording. Notification access is optional for message alerts. Android document dialogs grant access to selected import/export and cloud files. Delete individual messages, sessions, waypoints or maps in the app; Settings → Storage offers confirmed cleanup. Uninstalling removes app-private data but does not delete exports, shared files or cloud backups. Android settings manages permissions.'),
          _HelpSection('Testing and support',
              'This build still needs testing on your phone and radio. Recovery is best effort; it cannot bypass force-stop or manufacturer restrictions. There is a small message-loss window before a fetched packet is saved. For an issue, record the app version, phone/Android version, radio firmware, steps and expected result. Remove private messages, coordinates, passwords and keys before sharing a report. Source and issue tracker: github.com/charlottemeshtastic/Mesh-Scout. MeshScout is independent from BackCountrySignal.'),
        ]),
      );
}

class _HelpSection extends StatelessWidget {
  const _HelpSection(this.title, this.body);
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          const SizedBox(height: 8),
          Text(body),
        ]),
      );
}
