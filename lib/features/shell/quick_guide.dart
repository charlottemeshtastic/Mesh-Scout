import 'package:flutter/material.dart';

class _GuidePage {
  const _GuidePage(this.icon, this.title, this.body);
  final IconData icon;
  final String title, body;
}

const _pages = [
  _GuidePage(Icons.travel_explore, 'Welcome to MeshScout',
      'MeshScout records where your MeshCore radio hears the mesh. Everything stays on this phone unless you export or back it up.'),
  _GuidePage(Icons.bluetooth_searching, 'Connect your radio',
      'Open Radios, tap Scan for radios, then Connect. MeshScout checks the companion firmware before sending any commands.'),
  _GuidePage(Icons.play_arrow, 'Start Mapping',
      'On the Map tab, tap Start Mapping. Each received packet is tagged with your GPS position from the last 15 seconds.'),
  _GuidePage(Icons.circle, 'Read the dots',
      'Green is −90 dBm or better, orange down to −110 dBm, red below that. Dots show last-hop reception only, not two-way coverage.'),
  _GuidePage(Icons.local_parking, 'Auto-stop when parked',
      'A route stops and saves itself after 10 minutes in one spot. Recordings also end if the fixes look like a flight. Change both in Settings → Recording.'),
  _GuidePage(Icons.notifications_active_outlined, 'Disconnect alerts',
      'If the radio drops while connected you get an alert, and MeshScout retries the link. Disconnecting yourself is silent.'),
  _GuidePage(Icons.grid_on, 'Find the gaps',
      'Turn on All saved coverage on the Map, then Last 30 days only. Older cells disappear, so the places to map next stand out.'),
  _GuidePage(Icons.layers, 'Nodes on one rooftop',
      'Nodes at the same spot share a marker with a count. Tap it to zoom in, then tap again to choose one. Edge colour shows how recently it advertised.'),
  _GuidePage(Icons.history, 'History and export',
      'Every route is saved in History with its radio preset. Export a route as CSV or GeoJSON, including altitude.'),
  _GuidePage(Icons.download_for_offline_outlined, 'Offline maps',
      'Save up to five map areas before heading out of signal, or import your own MBTiles pack.'),
  _GuidePage(Icons.save_outlined, 'Back up your data',
      'Settings → Backup and storage makes an encrypted backup of routes, messages and waypoints. Keep the passphrase somewhere safe.'),
  _GuidePage(Icons.check_circle_outline, 'You are ready',
      'Open this guide again any time from Settings → About and support.'),
];

/// First-run tour, reopenable from Settings → About and support.
class QuickGuideScreen extends StatefulWidget {
  const QuickGuideScreen({super.key});

  @override
  State<QuickGuideScreen> createState() => _QuickGuideScreenState();
}

class _QuickGuideScreenState extends State<QuickGuideScreen> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _pages.length - 1) {
      Navigator.pop(context);
    } else {
      _controller.jumpToPage(_page + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _page == _pages.length - 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick guide'),
        actions: [
          if (!last)
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Skip')),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) {
                final page = _pages[i];
                return ListView(padding: const EdgeInsets.all(24), children: [
                  Icon(page.icon, size: 64),
                  const SizedBox(height: 24),
                  Semantics(
                      header: true,
                      child: Text(page.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall)),
                  const SizedBox(height: 16),
                  Text(page.body,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge),
                ]);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                  child: Text('${_page + 1} of ${_pages.length}',
                      style: Theme.of(context).textTheme.bodySmall)),
              FilledButton(
                  onPressed: _next, child: Text(last ? 'Done' : 'Next')),
            ]),
          ),
        ]),
      ),
    );
  }
}
