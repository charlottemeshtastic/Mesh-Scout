import 'dart:convert';
import 'dart:typed_data';

class MeshContact {
  const MeshContact(
      {required this.key,
      required this.name,
      required this.type,
      required this.lastAdvert,
      required this.latitude,
      required this.longitude,
      this.frame = const []});
  final List<int> frame;
  final String key;
  final String name;
  final int type;
  final DateTime? lastAdvert;
  final double? latitude;
  final double? longitude;
  String get typeLabel => switch (type) {
        1 => 'Chat node',
        2 => 'Repeater',
        3 => 'Room server',
        4 => 'Sensor',
        _ => 'Unknown type',
      };
  static MeshContact parse(List<int> bytes) {
    if (bytes.length < 148 || (bytes[0] != 3 && bytes[0] != 0x8a)) {
      throw const FormatException('Invalid contact frame');
    }
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    final nameBytes = bytes.sublist(100, 132).takeWhile((b) => b != 0).toList();
    final lat = data.getInt32(136, Endian.little) / 1000000;
    final lon = data.getInt32(140, Endian.little) / 1000000;
    final location =
        lat.abs() <= 90 && lon.abs() <= 180 && (lat != 0 || lon != 0);
    final timestamp = data.getUint32(132, Endian.little);
    return MeshContact(
        key: bytes
            .sublist(1, 33)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        name: utf8.decode(nameBytes, allowMalformed: true),
        type: bytes[33],
        lastAdvert: timestamp == 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(timestamp * 1000,
                isUtc: true),
        latitude: location ? lat : null,
        longitude: location ? lon : null,
        frame: List.unmodifiable(bytes.take(148)));
  }
}

/// Raw LoRa reception metrics reported by the companion, not BLE RSSI.
/// Firmware emits these before packet validation; sender/delivery is unknown.
class RxObservation {
  const RxObservation(this.rssi, this.snr, this.time);
  final int rssi;
  final double snr;
  final DateTime time;
  static RxObservation? parse(List<int> bytes, DateTime now) {
    if (bytes.length < 4 || bytes.first != 0x88) return null;
    int signed(int value) => value >= 128 ? value - 256 : value;
    final rssi = signed(bytes[2]);
    if (rssi > 0) return null;
    return RxObservation(rssi, signed(bytes[1]) / 4, now);
  }
}
