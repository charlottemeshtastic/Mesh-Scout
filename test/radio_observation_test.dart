import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/radio/radio_observation.dart';

void main() {
  final time = DateTime.utc(2026, 10, 10, 12);

  test('RF log converts signed RSSI and quarter-dB SNR, discards payload', () {
    final frame = [0x88, 0xf9, 0x9c, 0x11, 0, 0xaa];
    final observation = parseRadioObservation(frame, time)!;
    expect(observation.rssiDbm, -100);
    expect(observation.snrDb, -1.75);
    expect(observation.payloadType, 4);
    expect(observation.payloadVersion, 0);
    expect(observation.isFlood, isTrue);
    expect(observation.pathHashCount, 0);
    expect(observation.packetBytes, 3);
    expect(observation.receivedAt, time);
    frame[2] = 0;
    expect(observation.rssiDbm, -100);
  });

  test('transport routes skip four codes before multi-byte path hashes', () {
    for (final route in [0, 3]) {
      final observation = parseRadioObservation([
        0x88,
        12,
        0x80,
        0x94 | route,
        1,
        2,
        3,
        4,
        0x82,
        10,
        11,
        12,
        13,
        14,
        15,
        0xaa
      ], time)!;
      expect(observation.routeType, route);
      expect(observation.payloadType, 5);
      expect(observation.payloadVersion, 2);
      expect(observation.pathHashCount, 2);
      expect(observation.pathHashSize, 3);
      expect(observation.snrDb, 3);
      expect(observation.rssiDbm, -128);
      expect(observation.isFlood, route == 0);
    }
  });

  test('direct path length describes route hashes, not observed hop count', () {
    final observation = parseRadioObservation(
        [0x88, 0, 0xff, 0x0a, 0x42, 1, 2, 3, 4, 0xaa], time)!;
    expect(observation.isFlood, isFalse);
    expect(observation.pathHashCount, 2);
    expect(observation.pathHashSize, 2);
    expect(observation.payloadType, 2);
  });

  test(
      'rejects truncated headers and paths, reserved sizes, oversize and nonbytes',
      () {
    for (final frame in <List<int>>[
      [],
      [0x88],
      [0x88, 0, 0, 0x11, 0],
      [0x88, 0, 0, 0x10, 1, 2, 3, 4],
      [0x88, 0, 0, 0x11, 2, 1, 2],
      [0x88, 0, 0, 0x11, 0xc0, 1],
      [0x88, 0, 0, 0x11, 0x96, ...List.filled(67, 1)],
      [0x88, 0, 0, 0x11, 0, ...List.filled(172, 1)],
      [0x88, -1, 0, 0x11, 0, 1],
      [0x88, 0, 0, 0x11, 0, 256],
      [0x80, ...List.filled(32, 0)],
      [0x07, ...List.filled(20, 0)],
    ]) {
      expect(parseRadioObservation(frame, time), isNull, reason: '$frame');
    }
  });

  test('accepts frame and encoded path size boundaries', () {
    final frame = [0x88, 127, 127, 0x11, 0x60, ...List.filled(171, 1)];
    expect(frame.length, 176);
    final observation = parseRadioObservation(frame, time)!;
    expect(observation.pathHashCount * observation.pathHashSize, 64);
    expect(observation.snrDb, 31.75);
    expect(observation.rssiDbm, 127);
  });
}
