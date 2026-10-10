/// BLE UART candidates are untrusted until the companion handshake succeeds.
class RadioDevice {
  const RadioDevice(this.id, this.name, this.rssi);
  final String id;
  final String name;
  /// Phone-to-radio BLE RSSI; never a LoRa coverage observation.
  final int rssi;
}

enum RadioLink { connecting, connected, disconnected }
enum RadioFailure { denied, permanentlyDenied, unavailable, transport, protocol }

class RadioException implements Exception {
  const RadioException(this.failure);
  final RadioFailure failure;
}

abstract interface class BleService {
  Future<void> authorize();
  Stream<RadioDevice> scan();
  Stream<RadioLink> connect(String id);
  Future<void> discover(String id);
  Future<int> negotiateMtu(String id);
  Stream<List<int>> notifications(String id);
  Future<void> write(String id, List<int> bytes);
  Future<void> openSettings();
}

const meshCoreService = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const meshCoreRx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const meshCoreTx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

/// APP_START with seven reserved bytes and an ASCII application name.
const appStart = [1, 0, 0, 0, 0, 0, 0, 0, 77, 101, 115, 104, 83, 99, 111, 117, 116];
const deviceQuery = [0x16, 3];

/// Android 12 moved companion discovery to Nearby Devices permissions.
enum BluetoothAccess { scan, connect, location }
List<BluetoothAccess> permissionPlan(int sdk) => sdk >= 31
    ? const [BluetoothAccess.scan, BluetoothAccess.connect]
    : const [BluetoothAccess.location];

/// SELF_INFO includes a variable node name and DEVICE_INFO exceeds 20 bytes.
/// Reserve capacity for the identification replies plus ATT overhead.
const minimumIdentificationMtu = 93;
const requestedCompanionMtu = 185;
