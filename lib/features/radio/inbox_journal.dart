import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../offline/offline_maps.dart';

final inboxJournalProvider = Provider<InboxJournal>(
    (ref) => InboxJournal(ref.read(dataDirectoryProvider)));

/// A durable single-message inbox checkpoint, written before retrieval completes.
class InboxJournal {
  InboxJournal(this.directory);
  final Future<String> Function() directory;
  Future<File> get file async =>
      File('${await directory()}/inbox-journal.json');
  Future<void> write(List<int> bytes, String radio) async {
    final target = await file;
    if (target.existsSync()) {
      throw StateError(
          'Recover the pending inbox message before fetching more.');
    }
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
        jsonEncode({
          'radio': radio,
          'frame': bytes,
          'id': DateTime.now().microsecondsSinceEpoch.toString()
        }),
        flush: true);
    await temp.rename(target.path);
  }

  Future<Map<String, dynamic>?> read() async {
    final target = await file;
    if (!target.existsSync()) return null;
    if (await target.length() > 4096) {
      throw const FormatException('Invalid inbox checkpoint.');
    }
    return jsonDecode(await target.readAsString()) as Map<String, dynamic>;
  }

  Future<void> clear() async {
    final target = await file;
    if (target.existsSync()) {
      await target.delete();
    }
  }
}
