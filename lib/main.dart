import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['MeshMapper'],
      await rootBundle.loadString('assets/licenses/MeshMapper-MIT.txt'),
    );
  });
  runApp(
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
      child: const MeshScoutStartup(),
    ),
  );
}

class MeshScoutApp extends StatelessWidget {
  const MeshScoutApp({super.key, this.mapContent, this.showBranding = false});

  /// Allows offline rendering in interface tests without requesting map tiles.
  final Widget? mapContent;

  final bool showBranding;

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
        builder: (context, child) => Stack(
          children: [
            child!,
            if (showBranding)
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xFF05090D),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Image.asset(
                        'assets/branding/meshscout-logo.jpg',
                        fit: BoxFit.contain,
                        semanticLabel: 'MeshScout',
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

/// Displays the supplied full artwork while the existing application starts.
class MeshScoutStartup extends StatefulWidget {
  const MeshScoutStartup({super.key});

  @override
  State<MeshScoutStartup> createState() => _MeshScoutStartupState();
}

class _MeshScoutStartupState extends State<MeshScoutStartup> {
  late final Timer _timer;
  bool _showBranding = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _showBranding = false);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      MeshScoutApp(showBranding: _showBranding);
}
