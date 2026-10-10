import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ble_service.dart';
import 'radio_notifier.dart';

class RadioScreen extends ConsumerStatefulWidget {
  const RadioScreen({super.key, this.embedded = false});
  final bool embedded;
  @override
  ConsumerState<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends ConsumerState<RadioScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    if (!widget.embedded) {
      WidgetsBinding.instance.addObserver(this);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(ref.read(radioProvider.notifier).background());
    } else if (state == AppLifecycleState.detached) {
      unawaited(ref.read(radioProvider.notifier).disconnect());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(radioProvider);
    final actions = ref.read(radioProvider.notifier);
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          unawaited(actions.disconnect());
        }
      },
      child: Scaffold(
        appBar: widget.embedded
            ? null
            : AppBar(title: const Text('MeshCore radio')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text(
              'Connect a MeshCore companion radio. Nearby devices permission is used to find your radio. Android 11 and earlier also require location permission and location services for scanning.'),
          const SizedBox(height: 16),
          Text(switch (state.phase) {
            RadioPhase.idle => 'Ready to scan',
            RadioPhase.authorizing => 'Checking Bluetooth permissions…',
            RadioPhase.scanning => 'Scanning for nearby radios…',
            RadioPhase.connecting => 'Connecting…',
            RadioPhase.identifying => 'Checking MeshCore companion protocol…',
            RadioPhase.ready => 'MeshCore companion connected',
            RadioPhase.failed => switch (state.failure) {
                RadioFailure.denied =>
                  'Permission denied. Allow Bluetooth access to scan.',
                RadioFailure.permanentlyDenied =>
                  'Permission blocked. Enable it in app settings.',
                RadioFailure.unavailable =>
                  'Bluetooth unavailable. Enable Bluetooth and, on older Android, location services.',
                RadioFailure.protocol =>
                  'MeshCore identification failed or timed out. Check companion firmware and pairing.',
                _ => 'Bluetooth connection failed. Check your radio and retry.',
              },
          }),
          const SizedBox(height: 12),
          if (!state.busy)
            FilledButton(
                onPressed: () async => actions.scan(),
                child: const Text('Scan for radios')),
          if (state.phase == RadioPhase.scanning)
            OutlinedButton(
                onPressed: () async => actions.stopScan(),
                child: const Text('Stop scan')),
          if (state.busy && state.phase != RadioPhase.scanning)
            OutlinedButton(
                onPressed: () async => actions.disconnect(),
                child: const Text('Disconnect / cancel')),
          if (state.failure == RadioFailure.permanentlyDenied)
            TextButton(
                onPressed: () async => actions.openSettings(),
                child: const Text('Open app settings')),
          if (state.phase == RadioPhase.idle && state.devices.isEmpty)
            const Text(
                'Scan runs for up to 10 seconds. Connect as soon as your radio appears.'),
          for (final device in state.devices)
            ListTile(
              title: Text(device.name.isEmpty
                  ? 'Nearby Bluetooth device'
                  : device.name),
              subtitle: Text('${device.id} · BLE signal ${device.rssi} dBm'),
              trailing: TextButton(
                  onPressed: state.phase == RadioPhase.idle ||
                          state.phase == RadioPhase.scanning
                      ? () async => actions.connect(device)
                      : null,
                  child: const Text('Connect')),
            ),
          const SizedBox(height: 16),
          const Text(
              'Results are Bluetooth candidates. MeshCore compatibility is checked after connecting. Bluetooth signal strength describes the phone-to-radio link. GPS routes are available on Map. LoRa coverage measurements are not implemented.'),
        ]),
      ),
    );
  }
}
