import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_scout/features/export/message_export.dart';
import 'package:mesh_scout/features/messages/messages.dart';

void main() {
  Map<String, dynamic> item(String body, {bool outgoing = false}) => {'radio':'radio-a','peer':'Channel 0','body':body,'time':1,'status':'delivery unconfirmed','outgoing':outgoing,'tag':42,'secret':'do not export'};
  test('JSON preserves exact text, UTC, direction and status, omitting extra fields', () {
    final data = jsonDecode(exportMessages([item('=1+1\n"héllo"')], MessageExportFormat.json)) as Map<String,dynamic>;
    expect(data['version'],1);
    final message = (data['messages'] as List<dynamic>).single as Map<String,dynamic>;
    expect(message['body'],'=1+1\n"héllo"'); expect(message['time_utc'],'1970-01-01T00:00:01.000Z');
    expect(message['direction'],'incoming'); expect(message['status'],'delivery unconfirmed');
    expect(message.containsKey('tag'),false); expect(message.containsKey('secret'),false);
  });
  test('CSV quotes commas, quotes and multiline text', () {
    final csv = exportMessages([item('hello, "friend"\nnext')], MessageExportFormat.csv);
    expect(csv,contains('"hello, ""friend""\nnext"')); expect(csv,contains('\r\n'));
  });
  test('CSV neutralizes formula prefixes including leading whitespace', () {
    for(final body in ['=1+1',' +SUM(A1)','-42','@test','\t=1']) {
      final csv = exportMessages([item(body)],MessageExportFormat.csv);
      expect(csv,contains('"\'$body"'));
    }
  });
  test('empty JSON and CSV remain valid exports without fabricated messages', () {
    final json = jsonDecode(exportMessages([],MessageExportFormat.json)) as Map<String,dynamic>;
    expect(json['messages'],isEmpty); expect(exportMessages([],MessageExportFormat.csv).split('\r\n').length,1);
  });
  test('search is case insensitive across body, peer and status', () {
    final items=[item('Mountain trail'),item('Valley')];
    expect(filterMessages(items,'MOUNTAIN','all').length,1);
    expect(filterMessages(items,'channel 0','all').length,2);
    expect(filterMessages(items,'unconfirmed','all').length,2);
    expect(filterMessages(items,'missing','all'),isEmpty);
  });
  test('direction filters combine with query and leave original history untouched', () {
    final items=[item('hello'),item('hello',outgoing:true),item('other',outgoing:true)];
    expect(filterMessages(items,'hello','incoming').length,1);
    expect(filterMessages(items,'hello','outgoing').length,1);
    expect(items.length,3);
  });
}
