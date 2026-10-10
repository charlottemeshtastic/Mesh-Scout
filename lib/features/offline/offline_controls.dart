import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'offline_maps.dart';

class OfflineControls extends ConsumerWidget {
  const OfflineControls({super.key, required this.center});
  final ({double lat, double lon}) Function() center;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineProvider);
    final actions = ref.read(offlineProvider.notifier);
    return Column(children: [
      if (offline.busy)
        LinearProgressIndicator(
            value:
                offline.total == 0 ? null : offline.progress / offline.total),
      Row(children: [
        Expanded(
            child: TextButton.icon(
                onPressed: offline.busy
                    ? actions.cancel
                    : () async {
                        final point = center();
                        final accepted = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                                    title: const Text('Download offline topo?'),
                                    content: Text(
                                        'Save a 4 × 4 km area around ${point.lat.toStringAsFixed(4)}, ${point.lon.toStringAsFixed(4)} at zoom 12–16. Contiguous U.S. only; up to 50 MB. This replaces the previous offline area after a complete download.'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(c, false),
                                          child: const Text('Cancel')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(c, true),
                                          child: const Text('Download'))
                                    ]));
                        if (accepted == true)
                          await actions.download(point.lat, point.lon);
                      },
                icon: Icon(offline.busy
                    ? Icons.cancel_outlined
                    : Icons.download_outlined),
                label: Text(offline.busy
                    ? 'Cancel · ${offline.progress}/${offline.total}'
                    : 'Download area'))),
        const Text('Offline'),
        Switch(
            value: offline.enabled,
            onChanged:
                offline.busy || offline.area == null ? null : actions.enable),
        if (offline.area != null)
          IconButton(
              tooltip: 'Delete offline area',
              onPressed: offline.busy
                  ? null
                  : () async {
                      final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                                  title: const Text('Delete offline area?'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, false),
                                        child: const Text('Cancel')),
                                    FilledButton(
                                        onPressed: () => Navigator.pop(c, true),
                                        child: const Text('Delete'))
                                  ]));
                      if (yes == true) {
                        try {
                          await actions.delete();
                        } catch (_) {
                          if (context.mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'Could not delete offline area.')));
                        }
                      }
                    },
              icon: const Icon(Icons.delete_outline))
      ]),
      if (offline.message != null)
        Text(offline.message!, style: Theme.of(context).textTheme.bodySmall),
      if (offline.enabled)
        Text(
            'Offline topo · zoom 12–16 · saved near ${offline.area!.latitude.toStringAsFixed(3)}, ${offline.area!.longitude.toStringAsFixed(3)}. Outside the downloaded area, no basemap is available.',
            style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
