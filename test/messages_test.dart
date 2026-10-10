import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/messages/messages.dart';
import 'package:mesh_scout/features/offline/offline_maps.dart';
import 'package:mesh_scout/features/mapping/mapping_service.dart';

void main() {
  final key = List.filled(32, 'ab').join();
  test('direct message encodes timestamp, prefix and UTF-8 without retries',
      () {
    final bytes = directMessage(key, 'hello', 0x04030201, 185);
    expect(bytes.take(7), [2, 0, 0, 1, 2, 3, 4]);
    expect(bytes.sublist(7, 13), List.filled(6, 171));
    expect(utf8.decode(bytes.sublist(13)), 'hello');
  });
  test('message byte and MTU limits reject multibyte text and controls', () {
    expect(() => directMessage(key, List.filled(67, 'é').join(), 1, 185),
        throwsFormatException);
    expect(() => directMessage(key, 'hello', 1, 20), throwsFormatException);
    expect(
        () => directMessage(key, 'bad\ntext', 1, 185), throwsFormatException);
    expect(() => directMessage(key, '', 1, 185), throwsFormatException);
  });
  test('channel frame encodes selected slot and enforces prefix-safe byte limit', () {
    final bytes = channelMessage(2,'hello',0x04030201,185);
    expect(bytes.take(7),[3,0,2,1,2,3,4]);
    expect(utf8.decode(bytes.sublist(7)),'hello');
    expect(() => channelMessage(2,List.filled(50,'é').join(),1,185),throwsFormatException);
    expect(() => channelMessage(-1,'hello',1,185),throwsFormatException);
    expect(() => channelMessage(2,'hello',1,14),throwsFormatException);
  });
  test('incoming legacy direct message preserves sender prefix and timestamp',
      () {
    final m = incomingMessage(
        [7, 1, 2, 3, 4, 5, 6, 0, 0, 1, 0, 0, 0, ...utf8.encode('hello')]);
    expect(m['peer'], '010203040506');
    expect(m['time'], 1);
    expect(m['body'], 'hello');
  });
  test('incoming V3 channel and signed direct message offsets', () {
    final m = incomingMessage(
        [17, 0, 0, 0, 2, 0, 0, 1, 0, 0, 0, ...utf8.encode('channel')]);
    expect(m['peer'], 'Channel 2');
    expect(m['body'], 'channel');
    final signed = incomingMessage([
      16,
      0,
      0,
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      0,
      2,
      1,
      0,
      0,
      0,
      9,
      9,
      9,
      9,
      ...utf8.encode('forwarded')
    ]);
    expect(signed['body'], 'forwarded');
    expect(signed['status'], contains('unverified'));
  });
  test('malformed, CLI and unsupported incoming data is rejected', () {
    expect(() => incomingMessage([7]), throwsFormatException);
    expect(() => incomingMessage([27, 0]), throwsFormatException);
    expect(() => incomingMessage([7, 1, 2, 3, 4, 5, 6, 0, 1, 1, 0, 0, 0, 65]),
        throwsFormatException);
    expect(() => incomingMessage([7, 1, 2, 3, 4, 5, 6, 0, 0, 1, 0, 0, 0, 255]),
        throwsFormatException);
  });
  test('larger areas increase coverage and reject unsupported sizes', () {
    expect(areaTiles(35.2, -80.8, sideKm: 8).length,
        greaterThan(areaTiles(35.2, -80.8).length));
    expect(areaTiles(35.2, -80.8, sideKm: 12).length,
        greaterThan(areaTiles(35.2, -80.8, sideKm: 8).length));
    expect(() => areaTiles(35.2, -80.8, sideKm: 40), throwsFormatException);
  });
  test('session names survive JSON and old sessions remain readable', () {
    final s = MappingSession(
        id: 'a',
        started: DateTime.utc(2026),
        ended: DateTime.utc(2026),
        points: const []);
    expect(MappingSession.fromJson(s.toJson()).name, isNull);
    final named = s.renamed('Evening trail');
    expect(MappingSession.fromJson(named.toJson()).name, 'Evening trail');
    expect(named.id, s.id);
  });
}
