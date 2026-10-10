import 'dart:convert';
import 'package:flutter/services.dart';

enum MessageExportFormat { json, csv }

String exportMessages(
    List<Map<String, dynamic>> items, MessageExportFormat format) {
  final messages = [
    for (final item in items)
      {
        'radio_id': item['radio'] as String,
        'peer': item['peer'] as String,
        'direction': item['outgoing'] == true ? 'outgoing' : 'incoming',
        'time_utc': DateTime.fromMillisecondsSinceEpoch(
                (item['time'] as int) * 1000,
                isUtc: true)
            .toIso8601String(),
        'status': item['status'] as String,
        'body': item['body'] as String,
      }
  ];
  if (format == MessageExportFormat.json) {
    return jsonEncode({
      'format': 'meshscout-message-history',
      'version': 1,
      'messages': messages
    });
  }
  const columns = [
    'radio_id',
    'peer',
    'direction',
    'time_utc',
    'status',
    'body'
  ];
  String cell(String value) {
    // Quoting alone does not neutralize spreadsheet formulas from received text.
    final trimmed = value.trimLeft();
    final safe = trimmed.isNotEmpty &&
            ('=+-@'.contains(trimmed[0]) || trimmed.codeUnitAt(0) < 32)
        ? "'$value"
        : value;
    return '"${safe.replaceAll('"', '""')}"';
  }

  return [
    columns.map(cell).join(','),
    for (final item in messages)
      columns.map((key) => cell(item[key]!)).join(',')
  ].join('\r\n');
}

class MessageExportService {
  static const channel = MethodChannel('org.meshscout/files');
  Future<bool> send(
      List<Map<String, dynamic>> items, MessageExportFormat format,
      {required bool share}) async {
    final extension = format == MessageExportFormat.json ? 'json' : 'csv';
    return await channel.invokeMethod<bool>(share ? 'share' : 'save', {
          'name':
              'MeshScout-Messages-${DateTime.now().millisecondsSinceEpoch}.$extension',
          'mime': format == MessageExportFormat.json
              ? 'application/json'
              : 'text/csv',
          'content': exportMessages(items, format),
        }) ??
        false;
  }
}
