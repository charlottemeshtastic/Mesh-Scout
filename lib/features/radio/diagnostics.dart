import 'dart:typed_data';

String pathDescription(List<int> bytes) {
  var offset = 8;
  String path(String direction) {
    if (offset >= bytes.length) throw const FormatException('Truncated path.');
    final encoded = bytes[offset++],
        count = encoded & 63,
        width = (encoded >> 6) + 1;
    if (count > 64 || width > 3 || offset + count * width > bytes.length)
      throw const FormatException('Invalid path.');
    final hops = <String>[];
    for (var i = 0; i < count; i++) {
      hops.add(bytes
          .sublist(offset, offset + width)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join());
      offset += width;
    }
    return '$direction: ${count == 0 ? "direct" : hops.join(" → ")} ($count hops; $width-byte repeater hashes, not unique identities)';
  }

  final out = path('Outbound'), back = path('Return');
  if (offset != bytes.length)
    throw const FormatException('Unexpected path data.');
  return '$out\n$back';
}

String telemetryDescription(List<int> payload) {
  final data = ByteData.sublistView(Uint8List.fromList(payload));
  var offset = 0;
  final values = <String>[];
  int signed24(int at) {
    final value =
        (payload[at] << 16) | (payload[at + 1] << 8) | payload[at + 2];
    return value & 0x800000 != 0 ? value - 0x1000000 : value;
  }

  const lengths = {
    0: 1,
    1: 1,
    2: 2,
    3: 2,
    101: 2,
    102: 1,
    103: 2,
    104: 1,
    113: 6,
    115: 2,
    116: 2,
    117: 2,
    118: 4,
    120: 1,
    121: 2,
    128: 2,
    134: 6,
    136: 9
  };
  while (offset < payload.length) {
    if (offset + 2 > payload.length)
      throw const FormatException('Truncated telemetry.');
    final channel = payload[offset++],
        type = payload[offset++],
        length = lengths[type];
    if (length == null) {
      values.add(
          'Channel $channel: unsupported type $type; remaining raw ${payload.skip(offset).map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}');
      break;
    }
    if (offset + length > payload.length)
      throw const FormatException('Truncated telemetry.');
    final value = switch (type) {
      2 || 3 => 'Analog ${(data.getInt16(offset) / 100).toStringAsFixed(2)}',
      101 => 'Light ${data.getUint16(offset)} lux',
      103 =>
        'Temperature ${(data.getInt16(offset) / 10).toStringAsFixed(1)} °C',
      104 => 'Humidity ${payload[offset] / 2} %',
      116 => 'Voltage ${data.getUint16(offset) / 100} V',
      117 => 'Current ${data.getUint16(offset) / 1000} A',
      118 => 'Frequency ${data.getUint32(offset)} Hz',
      120 => '${payload[offset]} %',
      121 => 'Altitude ${data.getInt16(offset)} m',
      128 => 'Power ${data.getUint16(offset)} W',
      115 => 'Pressure ${data.getUint16(offset) / 10} hPa',
      136 =>
        'GPS ${signed24(offset) / 10000}, ${signed24(offset + 3) / 10000}, altitude ${signed24(offset + 6) / 100} m',
      _ => 'Type $type: ${payload.sublist(offset, offset + length).join(", ")}'
    };
    values.add('Channel $channel: $value');
    offset += length;
  }
  return values.isEmpty ? 'No sensor values reported.' : values.join('\n');
}
