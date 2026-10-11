/// Metadata for a live RF reception reported by the companion radio.
/// Raw payloads, routing hashes and message contents are never retained.
class RadioObservation {
  const RadioObservation({
    required this.receivedAt,
    required this.rssiDbm,
    required this.snrDb,
    required this.routeType,
    required this.payloadType,
    required this.payloadVersion,
    required this.pathHashCount,
    required this.pathHashSize,
    required this.packetBytes,
  });

  final DateTime receivedAt;
  final int rssiDbm;
  final double snrDb;
  final int routeType;
  final int payloadType;
  final int payloadVersion;
  final int pathHashCount;
  final int pathHashSize;
  final int packetBytes;
  bool get isFlood => routeType == 0 || routeType == 1;
}

/// Parses PUSH_CODE_LOG_RX_DATA (0x88), following MyMesh::logRxRaw and
/// Packet::writeTo/readFrom. Bounds match MAX_FRAME_SIZE and MAX_PATH_SIZE.
/// This validates framing only, not packet authenticity or successful delivery.
RadioObservation? parseRadioObservation(List<int> frame, DateTime receivedAt) {
  if (frame.length < 6 ||
      frame.length > 176 ||
      frame.first != 0x88 ||
      frame.any((byte) => byte < 0 || byte > 255)) {
    return null;
  }
  final header = frame[3];
  final route = header & 3;
  // Transport routes carry two uint16 codes before the encoded path length.
  final pathOffset = route == 0 || route == 3 ? 8 : 4;
  if (frame.length <= pathOffset) return null;
  final path = frame[pathOffset];
  final count = path & 63;
  final hashSize = (path >> 6) + 1;
  final pathBytes = count * hashSize;
  if (hashSize == 4 ||
      pathBytes > 64 ||
      frame.length <= pathOffset + 1 + pathBytes) {
    return null;
  }
  int signed(int byte) => byte < 128 ? byte : byte - 256;
  return RadioObservation(
    receivedAt: receivedAt.toUtc(),
    rssiDbm: signed(frame[2]),
    snrDb: signed(frame[1]) / 4.0,
    routeType: route,
    payloadType: (header >> 2) & 15,
    payloadVersion: (header >> 6) & 3,
    pathHashCount: count,
    pathHashSize: hashSize,
    packetBytes: frame.length - 3,
  );
}
