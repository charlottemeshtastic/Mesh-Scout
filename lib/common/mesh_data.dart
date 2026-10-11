import '../features/radio/radio_observation.dart';
import 'dart:convert';
import 'dart:typed_data';

class MeshContact {
  const MeshContact({
    required this.key,
    required this.name,
    required this.type,
    required this.lastAdvert,
    required this.latitude,
    required this.longitude,
    this.frame = const [],
  });
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
          : DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true),
      latitude: location ? lat : null,
      longitude: location ? lon : null,
      frame: List.unmodifiable(bytes.take(148)),
    );
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
    final report = parseRadioObservation(bytes, now);
    return report == null ? null : RxObservation(report.rssiDbm, report.snrDb, report.receivedAt);
  }
}

/// LoRa modem settings a companion reports in its SELF_INFO reply.
class RadioPreset {
  const RadioPreset({
    required this.frequencyKhz,
    required this.bandwidthHz,
    required this.sf,
    required this.cr,
  });
  final int frequencyKhz, bandwidthHz, sf, cr;

  /// Reads frequency, bandwidth, SF and CR from a SELF_INFO frame, or null.
  static RadioPreset? fromSelfInfo(List<int> self) {
    if (self.length < 58 || self.first != 5) return null;
    final data = ByteData.sublistView(Uint8List.fromList(self));
    final preset = RadioPreset(
      frequencyKhz: data.getUint32(48, Endian.little),
      bandwidthHz: data.getUint32(52, Endian.little),
      sf: self[56],
      cr: self[57],
    );
    return preset.valid ? preset : null;
  }

  /// Parses [key] as written by [key], or returns null.
  static RadioPreset? parse(String? key) {
    final parts = key?.split('/').map(int.tryParse).toList();
    if (parts == null || parts.length != 4 || parts.contains(null)) {
      return null;
    }
    final preset = RadioPreset(
      frequencyKhz: parts[0]!,
      bandwidthHz: parts[1]!,
      sf: parts[2]!,
      cr: parts[3]!,
    );
    return preset.valid ? preset : null;
  }

  bool get valid =>
      frequencyKhz >= 150000 &&
      frequencyKhz <= 2500000 &&
      bandwidthHz >= 7000 &&
      bandwidthHz <= 500000 &&
      sf >= 5 &&
      sf <= 12 &&
      cr >= 5 &&
      cr <= 8;

  /// Stable storage form: kHz/Hz/SF/CR.
  String get key => '$frequencyKhz/$bandwidthHz/$sf/$cr';

  /// Short display form, e.g. "910.525 MHz · 62.5 kHz · SF7 · CR5".
  String get label {
    final bandwidth = bandwidthHz % 1000 == 0
        ? '${bandwidthHz ~/ 1000}'
        : (bandwidthHz / 1000).toString();
    return '${(frequencyKhz / 1000).toStringAsFixed(3)} MHz · $bandwidth kHz · SF$sf · CR$cr';
  }

  @override
  bool operator ==(Object other) => other is RadioPreset && other.key == key;
  @override
  int get hashCode => key.hashCode;
}
