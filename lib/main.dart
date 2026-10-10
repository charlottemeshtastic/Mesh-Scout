import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/radio/radio_notifier.dart';
import 'features/shell/mesh_scout_shell.dart';
import 'native/android_ble_service.dart';

void main() => runApp(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(
            AndroidBleService(),
          ),
        ],
        child: const MeshScoutApp(),
      ),
    );

class MeshScoutApp extends StatelessWidget {
  const MeshScoutApp({super.key, this.mapContent});

  /// Allows offline rendering in interface tests without requesting map tiles.
  final Widget? mapContent;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MeshScout',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          colorSchemeSeed: const Color(0xff55d4a2),
        ),
        home: MeshScoutShell(mapContent: mapContent),
      );
}
