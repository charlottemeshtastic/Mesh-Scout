import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'features/offline/offline_maps.dart';
import 'features/sync/cloud_sync.dart';
import 'features/mapping/smart_ping.dart';
import 'features/alerts/message_alerts.dart';
import 'native/android_alert_service.dart';
import 'features/alerts/link_alerts.dart';
import 'native/android_link_alert_service.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/radio/radio_notifier.dart';
import 'features/shell/mesh_scout_shell.dart';
import 'native/android_ble_service.dart';
import 'native/android_mapping_service.dart';
import 'features/mapping/mapping_notifier.dart';

void main() => runApp(
      ProviderScope(
        overrides: [
          cloudSyncServiceProvider.overrideWithValue(AndroidCloudSyncService()),
          smartPingTickProvider.overrideWithValue(const Duration(seconds: 10)),
          mapDirectoryProvider.overrideWithValue(
            () async => (await const MethodChannel('org.meshscout/files')
                .invokeMethod<String>('mapDirectory'))!,
          ),
          dataDirectoryProvider.overrideWithValue(
            () async => (await const MethodChannel('org.meshscout/files')
                .invokeMethod<String>('dataDirectory'))!,
          ),
          alertServiceProvider.overrideWithValue(AndroidAlertService()),
          linkAlertServiceProvider.overrideWithValue(AndroidLinkAlertService()),
          tripGuardIntervalProvider
              .overrideWithValue(const Duration(seconds: 30)),
          mappingServiceProvider.overrideWithValue(AndroidMappingService()),
          bleServiceProvider.overrideWithValue(AndroidBleService()),
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
          scaffoldBackgroundColor: const Color(0xFF101820),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF00D9FF),
            secondary: Color(0xFF28465A),
            surface: Color(0xFF101820),
            onSurface: Color(0xFFE6EDF3),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF101820),
            foregroundColor: Color(0xFF00D9FF),
          ),
        ),
        home: MeshScoutShell(mapContent: mapContent),
      );
}
