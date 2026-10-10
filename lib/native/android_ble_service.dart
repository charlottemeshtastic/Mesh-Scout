import 'dart:io';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import '../features/radio/ble_service.dart';

/// Android implementation. Plugins remain confined to this boundary.
class AndroidBleService implements BleService {
  AndroidBleService();
  // The plugin initializes on construction; defer it until permissions pass.
  late final FlutterReactiveBle _ble = FlutterReactiveBle();
  final _service = Uuid.parse(meshCoreService);

  @override
  Future<void> authorize() async {
    if (!Platform.isAndroid) {
      throw const RadioException(RadioFailure.unavailable);
    }
    final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
    final permissions = permissionPlan(sdk)
        .map((access) => switch (access) {
              BluetoothAccess.scan => Permission.bluetoothScan,
              BluetoothAccess.connect => Permission.bluetoothConnect,
              BluetoothAccess.location => Permission.locationWhenInUse,
            })
        .toList();
    final statuses = await permissions.request();
    if (statuses.values.any((s) => s.isPermanentlyDenied)) {
      throw const RadioException(RadioFailure.permanentlyDenied);
    }
    if (statuses.values.any((s) => !s.isGranted)) {
      throw const RadioException(RadioFailure.denied);
    }
    await _ble.initialize();
    final status = await _ble.statusStream
        .firstWhere(
          (s) => s != BleStatus.unknown,
        )
        .timeout(const Duration(seconds: 5));
    if (status != BleStatus.ready) {
      throw const RadioException(RadioFailure.unavailable);
    }
  }

  @override
  Stream<RadioDevice> scan() => _ble.scanForDevices(
        withServices: [_service],
        scanMode: ScanMode.lowLatency,
      ).map((d) => RadioDevice(d.id, d.name, d.rssi));

  @override
  Stream<RadioLink> connect(String id) async* {
    const session = MethodChannel('org.meshscout/radio_session');
    try {
      // Start from the user's foreground Connect action, before app switching.
      await session.invokeMethod<void>('start');
      yield* _ble.connectToAdvertisingDevice(
        id: id, withServices: [_service],
        prescanDuration: const Duration(seconds: 3),
        connectionTimeout: const Duration(seconds: 10),
      ).map((u) => switch (u.connectionState) {
        DeviceConnectionState.connected => RadioLink.connected,
        DeviceConnectionState.disconnected => RadioLink.disconnected,
        _ => RadioLink.connecting,
      });
    } finally {
      await session.invokeMethod<void>('stop');
    }
  }

  @override
  Future<void> discover(String id) async {
    await _ble.discoverAllServices(id);
    final services = await _ble.getDiscoveredServices(id);
    final matches = services.where((s) => s.id == _service);
    if (matches.length != 1) {
      throw const RadioException(RadioFailure.protocol);
    }
    final characteristics = matches.single.characteristics;
    final rx = characteristics.where((c) => c.id == Uuid.parse(meshCoreRx));
    final tx = characteristics.where((c) => c.id == Uuid.parse(meshCoreTx));
    if (rx.length != 1 ||
        tx.length != 1 ||
        !rx.single.isWritableWithResponse ||
        !tx.single.isNotifiable) {
      throw const RadioException(RadioFailure.protocol);
    }
  }

  @override
  Future<int> negotiateMtu(String id) =>
      _ble.requestMtu(deviceId: id, mtu: requestedCompanionMtu);

  QualifiedCharacteristic _characteristic(String id, String uuid) =>
      QualifiedCharacteristic(
          deviceId: id,
          serviceId: _service,
          characteristicId: Uuid.parse(uuid));

  @override
  Stream<List<int>> notifications(String id) =>
      _ble.subscribeToCharacteristic(_characteristic(id, meshCoreTx));

  @override
  Future<void> write(String id, List<int> bytes) =>
      _ble.writeCharacteristicWithResponse(_characteristic(id, meshCoreRx),
          value: bytes);

  @override
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
