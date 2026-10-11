import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'offline_maps.dart';

class OfflineControls extends ConsumerWidget {
  const OfflineControls({super.key, required this.center});
  final ({double lat, double lon}) Function() center;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineProvider);
    final actions = ref.read(offlineProvider.notifier);
    return Column(
      children: [
        if (offline.areas.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey(offline.area?.path),
            initialValue: offline.area?.path,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Saved offline area'),
            items: [
              for (final area in offline.areas)
                DropdownMenuItem(
                  value: area.path,
                  child: Text(
                    '${area.name ?? "Topo"} · ${area.sideKm} km · ${area.latitude.toStringAsFixed(3)}, ${area.longitude.toStringAsFixed(3)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: offline.busy
                ? null
                : (path) => actions.select(
                      offline.areas.firstWhere((a) => a.path == path),
                    ),
          ),
        if (offline.busy)
          LinearProgressIndicator(
            value: offline.total == 0 ? null : offline.progress / offline.total,
          ),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: offline.busy
                    ? actions.cancel
                    : () async {
                        final point = center();
                        final side = await showDialog<int>(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Download offline topo?'),
                            content: Text(
                              'Save an area around ${point.lat.toStringAsFixed(4)}, ${point.lon.toStringAsFixed(4)} at zoom 12–16 (4–12 km) or 10–14 (24–48 km). Contiguous U.S. only; up to 150 MB. Keeps up to five separate areas; existing areas are retained.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(c),
                                child: const Text('Cancel'),
                              ),
                              for (final side in [4, 8, 12, 24, 48])
                                TextButton(
                                  onPressed: () => Navigator.pop(c, side),
                                  child: Text('$side × $side km'),
                                ),
                            ],
                          ),
                        );
                        if (side != null) {
                          if (!context.mounted) {
                            return;
                          }
                          final name = await showDialog<String>(
                            context: context,
                            builder: (_) => const _AreaNameDialog(),
                          );
                          if (name != null) {
                            await actions.download(
                              point.lat,
                              point.lon,
                              sideKm: side,
                              name: name,
                            );
                          }
                        }
                      },
                icon: Icon(
                  offline.busy
                      ? Icons.cancel_outlined
                      : Icons.download_outlined,
                ),
                label: Text(
                  offline.busy
                      ? 'Cancel · ${offline.progress}/${offline.total}'
                      : 'Download area',
                ),
              ),
            ),
            const Text('Offline'),
            Switch(
              value: offline.enabled,
              onChanged:
                  offline.busy || offline.area == null ? null : actions.enable,
            ),
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
                                onPressed: () => Navigator.pop(c),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (yes == true) {
                          try {
                            await actions.delete();
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Could not delete offline area.',
                                  ),
                                ),
                              );
                            }
                          }
                        }
                      },
                icon: const Icon(Icons.delete_outline),
              ),
          ],
        ),
        Wrap(
          children: [
            TextButton(
              onPressed: offline.busy
                  ? null
                  : () async {
                      try {
                        await actions.resume();
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(content: Text('$e')));
                        }
                      }
                    },
              child: const Text('Resume download'),
            ),
            TextButton(
              onPressed: offline.busy || offline.area == null
                  ? null
                  : () async {
                      final name = await showDialog<String>(
                        context: context,
                        builder: (_) => const _AreaNameDialog(),
                      );
                      if (name != null) {
                        try {
                          await actions.rename(name);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text('$e')));
                          }
                        }
                      }
                    },
              child: const Text('Rename area'),
            ),
            TextButton(
              onPressed: offline.busy
                  ? null
                  : () async {
                      try {
                        await const MethodChannel('org.meshscout/files')
                            .invokeMethod<bool>('importMap');
                        await actions.initialize();
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Map import failed: $e')),
                          );
                        }
                      }
                    },
              child: const Text('Import raster MBTiles'),
            ),
          ],
        ),
        const Text(
          'Raster MBTiles supports larger regions worldwide: PNG/JPEG, up to 500 MB and 50,000 tiles. Use a map pack you have permission to download. Vector MBTiles is unsupported.',
        ),
        if (offline.message != null)
          Text(offline.message!, style: Theme.of(context).textTheme.bodySmall),
        if (offline.enabled)
          Text(
            '${offline.area!.sideKm} × ${offline.area!.sideKm} km offline map · zoom ${offline.area!.minZoom}–${offline.area!.maxZoom} · saved near ${offline.area!.latitude.toStringAsFixed(3)}, ${offline.area!.longitude.toStringAsFixed(3)}. Outside the downloaded area, no basemap is available.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    );
  }
}

class _AreaNameDialog extends StatefulWidget {
  const _AreaNameDialog();
  @override
  State<_AreaNameDialog> createState() => _AreaNameState();
}

class _AreaNameState extends State<_AreaNameDialog> {
  final text = TextEditingController();
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Name offline area'),
        content: TextField(
          controller: text,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Area name (optional)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('Download'),
          ),
        ],
      );
}
