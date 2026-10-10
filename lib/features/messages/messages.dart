import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../offline/offline_maps.dart';
import '../radio/radio_notifier.dart';
import '../export/message_export.dart';

List<int> directMessage(String key, String text, int timestamp, int mtu) {
  final body = utf8.encode(text);
  if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(key) ||
      body.isEmpty ||
      body.length > 133 ||
      body.length + 16 > mtu ||
      RegExp(r'[\x00-\x1f]').hasMatch(text)) {
    throw const FormatException(
        'Use 1–133 UTF-8 bytes, without control characters.');
  }
  final stamp = ByteData(4)..setUint32(0, timestamp, Endian.little);
  return [
    2,
    0,
    0,
    ...stamp.buffer.asUint8List(),
    for (var i = 0; i < 12; i += 2)
      int.parse(key.substring(i, i + 2), radix: 16),
    ...body
  ];
}

List<int> channelMessage(int channel, String text, int timestamp, int mtu) {
  final body = utf8.encode(text);
  // Reserve 34 bytes for the firmware's sender-name prefix to avoid truncation.
  if (channel < 0 ||
      channel > 63 ||
      body.isEmpty ||
      body.length > 99 ||
      body.length + 10 > mtu ||
      RegExp(r'[\x00-\x1f]').hasMatch(text)) {
    throw const FormatException(
        'Channel text supports 1–99 UTF-8 bytes without control characters.');
  }
  final stamp = ByteData(4)..setUint32(0, timestamp, Endian.little);
  return [3, 0, channel, ...stamp.buffer.asUint8List(), ...body];
}

Map<String, dynamic> incomingMessage(List<int> bytes) {
  if (bytes.isEmpty) {
    throw const FormatException('Empty message frame.');
  }
  final v3 = bytes.first == 16 || bytes.first == 17;
  final channel = bytes.first == 8 || bytes.first == 17;
  if (![7, 8, 16, 17].contains(bytes.first)) {
    throw const FormatException('Unsupported queued message.');
  }
  final prefix = v3 ? 4 : 1;
  final typeOffset = channel ? (v3 ? 6 : 3) : (v3 ? 11 : 8);
  if (bytes.length < typeOffset + 5) {
    throw const FormatException('Truncated message.');
  }
  final type = bytes[typeOffset];
  if ((type != 0 && type != 1 && type != 2) || channel && type == 1) {
    throw const FormatException('Unsupported message type.');
  }
  final offset = typeOffset + 5 + (type == 2 ? 4 : 0);
  if (bytes.length <= offset) {
    throw const FormatException('Empty or truncated message.');
  }
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  return {
    'peer': channel
        ? 'Channel ${bytes[prefix]}'
        : bytes
            .sublist(prefix, prefix + 6)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
    'body': utf8.decode(bytes.sublist(offset)),
    'time': data.getUint32(typeOffset + 1, Endian.little),
    'status': type == 2
        ? 'Received forwarded message · origin unverified'
        : type == 1 ? 'Received repeater CLI response' : 'Received',
    'outgoing': false
  };
}

final messagesProvider = NotifierProvider<Messages, MessageState>(Messages.new);

class MessageState {
  const MessageState(
      {this.items = const [],
      this.busy = false,
      this.loaded = false,
      this.notice});
  final List<Map<String, dynamic>> items;
  final bool busy, loaded;
  final String? notice;
}

class Messages extends Notifier<MessageState> {
  int _lastTimestamp = 0;
  final _acks = <String>{};
  final _live = <String>{};
  List<Map<String, dynamic>>? _unsaved;
  bool get hasUnsaved => _unsaved != null;
  @override
  MessageState build() {
    ref.listen(radioProvider.select((s) => s.messageEvent), (_, bytes) {
      if (bytes == null) {
        return;
      }
      if (bytes.first == 0x83 && !state.busy) {
        state = MessageState(
            items: state.items,
            loaded: state.loaded,
            notice: 'Messages waiting on radio. Tap Fetch messages.');
      }
      // ACKs are handled only after an accepted send in this live process.
      if (bytes.first == 0x82 && bytes.length == 9) {
        final tag = ByteData.sublistView(Uint8List.fromList(bytes))
            .getUint32(1, Endian.little);
        final id = ref.read(radioProvider.notifier).companionId;
        _acks.add('$id:$tag');
        if (!state.busy) {
          _confirm();
        }
      }
    });
    return const MessageState();
  }

  Future<File> _file() async =>
      File('${await ref.read(dataDirectoryProvider)()}/messages.json');
  Future<void> load() async {
    if (state.loaded || state.busy) {
      return;
    }
    state = MessageState(items: state.items, busy: true);
    try {
      final file = await _file();
      final items = file.existsSync()
          ? (jsonDecode(await file.readAsString()) as List<dynamic>)
              .map((m) => Map<String, dynamic>.from(m as Map<String, dynamic>))
              .toList()
          : <Map<String, dynamic>>[];
      if (items.length > 1000 ||
          items.any((m) =>
              m['body'] is! String ||
              m['peer'] is! String ||
              m['status'] is! String ||
              m['radio'] is! String ||
              m['time'] is! int ||
              m['outgoing'] is! bool)) {
        throw const FormatException();
      }
      // Stored acceptance is not a fresh delivery acknowledgement.
      if (ref.mounted) {
        state = MessageState(items: items, loaded: true);
      }
    } catch (_) {
      if (ref.mounted) {
        state = const MessageState(
            notice:
                'Could not load message history. Sending and fetching are blocked.');
      }
    }
  }

  Future<void> _save(List<Map<String, dynamic>> items) async {
    _unsaved = items;
    final file = await _file();
    final temporary = File('${file.path}.pending');
    await temporary.writeAsString(jsonEncode(items), flush: true);
    await temporary.rename(file.path);
    _unsaved = null;
    if (ref.mounted) {
      state = MessageState(items: items, loaded: true, busy: state.busy);
    }
  }

  void _confirm() {
    if (state.busy || _unsaved != null || !state.loaded) {
      return;
    }
    final updated = [
      for (final m in state.items) {...m}
    ];
    var changed = false;
    for (final m in updated) {
      final key = '${m['radio']}:${m['tag']}';
      if (_live.contains(key) &&
          _acks.contains(key) &&
          updated
                  .where((other) =>
                      other['radio'] == m['radio'] && other['tag'] == m['tag'])
                  .length ==
              1 &&
          m['status'] == 'Accepted by radio · delivery unconfirmed') {
        m['status'] = 'Delivery confirmed';
        changed = true;
      }
    }
    if (changed) {
      unawaited(_persistChange(updated));
    }
  }

  Future<void> _persistChange(List<Map<String, dynamic>> items) async {
    state = MessageState(items: state.items, loaded: true, busy: true);
    try {
      await _save(items);
    } catch (_) {/* Retain pending data for explicit retry. */}
    if (ref.mounted) {
      state = MessageState(
          items: _unsaved ?? state.items,
          loaded: true,
          notice: _unsaved == null
              ? null
              : 'Save failed. Retry saving before fetching or sending.');
      _confirm();
    }
  }

  Future<void> clearHistory() async {
    if (!state.loaded || state.busy || _unsaved != null) {
      return;
    }
    _live.clear();
    _acks.clear();
    await _persistChange([]);
  }

  Future<void> retrySave() async {
    if (_unsaved == null || state.busy) {
      return;
    }
    await _persistChange(_unsaved!);
  }

  bool get available =>
      state.loaded &&
      !state.busy &&
      _unsaved == null &&
      state.items.length < 1000 &&
      !ref.read(radioProvider).controlsBusy;
  Future<void> send(String key, String text, {int? channel}) async {
    if (!available) {
      return;
    }
    final radio = ref.read(radioProvider.notifier);
    final token = radio.sessionToken;
    final contacts = ref.read(radioProvider).contacts;
    if (channel == null &&
        (contacts
                    .where((c) => c.key.startsWith(
                        key.length >= 12 ? key.substring(0, 12) : key))
                    .length !=
                1 ||
            !contacts.any((c) => c.key == key && c.type == 1))) {
      return;
    }
    if (channel != null &&
        !ref.read(radioProvider).channels.any((c) => c.index == channel)) {
      return;
    }
    state = MessageState(items: state.items, loaded: true, busy: true);
    try {
      var stamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (stamp <= _lastTimestamp) {
        stamp = _lastTimestamp + 1;
      }
      _lastTimestamp = stamp;
      final command = channel == null
          ? directMessage(key, text, stamp, radio.mtu)
          : channelMessage(channel, text, stamp, radio.mtu);
      final record = <String, dynamic>{
        'peer': channel == null ? key.substring(0, 12) : 'Channel $channel',
        'body': text,
        'time': stamp,
        'radio': radio.companionId,
        'outgoing': true,
        'status': 'Send outcome unknown · never automatically retried'
      };
      await _save([...state.items, record]);
      if (radio.sessionToken != token) {
        throw StateError('Radio changed before send.');
      }
      final reply =
          await radio.messageCommand(command, channel == null ? {6} : {0});
      if (channel != null) {
        if (reply.length != 1) {
          throw const FormatException('Invalid channel acceptance.');
        }
        await _save([
          ...state.items.take(state.items.length - 1),
          {
            ...record,
            'status': 'Accepted by radio · channel delivery unconfirmed'
          }
        ]);
        return;
      }
      if (reply.length != 10) {
        throw const FormatException('Invalid radio acceptance.');
      }
      final tag = ByteData.sublistView(Uint8List.fromList(reply))
          .getUint32(2, Endian.little);
      if (tag != 0) {
        _live.add('${radio.companionId}:$tag');
      }
      await _save([
        ...state.items.take(state.items.length - 1),
        {
          ...record,
          'tag': tag,
          'status': 'Accepted by radio · delivery unconfirmed'
        }
      ]);
    } catch (e) {
      if (ref.mounted) {
        state = MessageState(
            items: _unsaved ?? state.items,
            loaded: true,
            busy: true,
            notice:
                'Send incomplete: $e. Reconnect before retrying; do not resend blindly.');
      }
    } finally {
      if (ref.mounted) {
        state = MessageState(
            items: _unsaved ?? state.items,
            loaded: true,
            notice:
                _unsaved != null ? 'Save failed. Retry saving.' : state.notice);
        _confirm();
      }
    }
  }

  Future<void> fetch() async {
    if (!available) {
      return;
    }
    final radio = ref.read(radioProvider.notifier);
    final token = radio.sessionToken;
    if (radio.mtu < 175) {
      state = MessageState(
          items: state.items,
          loaded: true,
          notice: 'Reconnect with a larger Bluetooth MTU before fetching.');
      return;
    }
    state = MessageState(items: state.items, loaded: true, busy: true);
    try {
      for (var i = 0; i < 100 && state.items.length < 1000; i++) {
        if (radio.sessionToken != token) {
          throw StateError('Radio changed during retrieval.');
        }
        final reply = await radio.messageCommand([10], {10, 7, 8, 16, 17, 27});
        if (reply.length == 1 && reply.first == 10) {
          break;
        }
        final record = incomingMessage(reply)..['radio'] = radio.companionId;
        await _save([...state.items, record]);
      }
    } catch (e) {
      if (ref.mounted) {
        state = MessageState(
            items: _unsaved ?? state.items,
            loaded: true,
            busy: true,
            notice:
                'Fetch stopped: $e. Unsupported messages have already left the radio queue.');
      }
    } finally {
      if (ref.mounted) {
        state = MessageState(
            items: _unsaved ?? state.items,
            loaded: true,
            notice: _unsaved != null
                ? 'Save failed. Retry saving before fetching more.'
                : state.notice);
        _confirm();
      }
    }
  }
}

List<Map<String, dynamic>> filterMessages(
        List<Map<String, dynamic>> items, String query, String direction) =>
    items
        .where((item) =>
            (direction == 'all' ||
                (direction == 'outgoing') == (item['outgoing'] == true)) &&
            '${item['peer']} ${item['body']} ${item['status']} ${item['radio']}'
                .toLowerCase()
                .contains(query.toLowerCase()))
        .toList();

class MessagesScreen extends ConsumerStatefulWidget {
  const MessagesScreen({super.key});
  @override
  ConsumerState<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends ConsumerState<MessagesScreen> {
  final _text = TextEditingController();
  String? _key;
  int? _channel;
  bool _channelMode = false;
  String _query = '';
  String _direction = 'all';
  bool _exporting = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) {
        return ref.read(messagesProvider.notifier).load();
      }
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(messagesProvider);
    final radio = ref.watch(radioProvider);
    final actions = ref.read(messagesProvider.notifier);
    final contacts = radio.contacts.where((c) => c.type == 1).toList();
    final visible = filterMessages(state.items, _query, _direction);
    final ready = !_exporting &&
        radio.phase == RadioPhase.ready &&
        !radio.syncing &&
        !radio.messagingBusy &&
        !radio.controlsBusy &&
        !radio.channelsLoading &&
        actions.available;
    return Scaffold(
        appBar: AppBar(title: const Text('Messages')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Text(
              'Direct and configured-channel messages. Fetch removes messages from the radio queue and saves them privately on this phone. A phone shutdown during retrieval can lose a message. History is limited to 1,000 messages.'),
          if (state.busy || _exporting) const LinearProgressIndicator(),
          OutlinedButton.icon(
              onPressed: !state.loaded ||
                      state.busy ||
                      _exporting ||
                      state.items.isEmpty
                  ? null
                  : () => _export(state.items),
              icon: const Icon(Icons.ios_share),
              label: const Text('Export message history')),
          if (state.notice != null) Text(state.notice!),
          if (state.items.length >= 1000)
            const Text('History is full. Clear history before fetching more.'),
          TextButton(
              onPressed: !state.loaded || state.busy || _exporting
                  ? null
                  : () async {
                      final yes = await showDialog<bool>(
                          context: context,
                          builder: (c) => AlertDialog(
                                  title: const Text('Clear message history?'),
                                  content: const Text(
                                      'This deletes all messages saved on this phone.'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, false),
                                        child: const Text('Cancel')),
                                    FilledButton(
                                        onPressed: () => Navigator.pop(c, true),
                                        child: const Text('Clear'))
                                  ]));
                      if (yes == true) {
                        await actions.clearHistory();
                      }
                    },
              child: const Text('Clear history')),
          OutlinedButton(
              onPressed: state.busy ? null : actions.retrySave,
              child: const Text('Retry saving')),
          FilledButton(
              onPressed: ready ? actions.fetch : null,
              child: const Text('Fetch messages')),
          SwitchListTile(
              title: const Text('Send to a channel'),
              value: _channelMode,
              onChanged: state.busy
                  ? null
                  : (value) => setState(() => _channelMode = value)),
          if (_channelMode) ...[
            OutlinedButton(
                onPressed: radio.phase == RadioPhase.ready &&
                        !state.busy &&
                        !radio.syncing &&
                        !radio.messagingBusy &&
                        !radio.controlsBusy &&
                        !radio.channelsLoading
                    ? ref.read(radioProvider.notifier).refreshChannels
                    : null,
                child: Text(radio.channelsLoading
                    ? 'Loading channels…'
                    : 'Load configured channels')),
            if (radio.contactMessage != null) Text(radio.contactMessage!),
            DropdownButtonFormField<int>(
                key: ValueKey(radio.channels),
                initialValue: radio.channels.any((c) => c.index == _channel)
                    ? _channel
                    : null,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Configured channel'),
                items: [
                  for (final c in radio.channels)
                    DropdownMenuItem(
                        value: c.index,
                        child: Text('${c.name} · ${c.index}',
                            overflow: TextOverflow.ellipsis))
                ],
                onChanged: (value) => setState(() => _channel = value)),
            const Text(
                'Channel sends have no delivery acknowledgement. Limit: 99 UTF-8 bytes.'),
          ],
          if (!_channelMode)
            DropdownButtonFormField<String>(
                key: ValueKey(radio.contacts),
                initialValue: contacts.any((c) => c.key == _key) ? _key : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Chat contact'),
                items: [
                  for (final c in contacts)
                    DropdownMenuItem(
                        value: c.key,
                        child: Text(
                            c.name.isEmpty ? c.key.substring(0, 12) : c.name,
                            overflow: TextOverflow.ellipsis))
                ],
                onChanged: (value) => setState(() => _key = value)),
          TextField(
              controller: _text,
              maxLength: _channelMode ? 99 : 133,
              decoration: InputDecoration(
                  labelText: _channelMode
                      ? 'Channel message (up to 99 UTF-8 bytes)'
                      : 'Direct message (up to 133 UTF-8 bytes)')),
          FilledButton(
              onPressed: ready &&
                      (_channelMode
                          ? radio.channels.any((c) => c.index == _channel)
                          : contacts.any((c) => c.key == _key))
                  ? () async {
                      final body = _text.text;
                      final before = state.items.length;
                      await actions.send(_key ?? '', body,
                          channel: _channelMode ? _channel : null);
                      if (!context.mounted) {
                        return;
                      }
                      final latest = ref.read(messagesProvider);
                      final accepted = latest.items.length > before &&
                          latest.items.last['body'] == body &&
                          (latest.items.last['status'] ==
                                  'Delivery confirmed' ||
                              (latest.items.last['status'] as String)
                                  .startsWith('Accepted by radio'));
                      if (accepted && _text.text == body) {
                        _text.clear();
                      }
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(accepted
                              ? 'Radio accepted the message. Check delivery status below.'
                              : latest.notice ??
                                  'Message was not accepted. Check connection and recipient.')));
                    }
                  : null,
              child: Text(_channelMode
                  ? 'Send channel message'
                  : 'Send direct message')),
          TextField(
              decoration:
                  const InputDecoration(labelText: 'Search message history'),
              onChanged: (value) => setState(() => _query = value)),
          DropdownButtonFormField<String>(
              initialValue: 'all',
              decoration: const InputDecoration(labelText: 'Show messages'),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('All messages')),
                DropdownMenuItem(
                    value: 'incoming', child: Text('Incoming only')),
                DropdownMenuItem(
                    value: 'outgoing', child: Text('Outgoing only'))
              ],
              onChanged: (value) =>
                  setState(() => _direction = value ?? 'all')),
          Text(
              '${visible.length} of ${state.items.length} messages · export includes all local history'),
          if (visible.isEmpty) const Text('No matching messages.'),
          for (final item in visible.reversed)
            ListTile(
                title: Text(item['body'] as String),
                subtitle: Text(
                    '${item['outgoing'] == true ? 'Outgoing' : 'Incoming'} · ${DateTime.fromMillisecondsSinceEpoch((item['time'] as int) * 1000).toLocal().toString().split('.').first}\n${item['peer']} · ${item['status']}')),
        ]));
  }

  Future<void> _export(List<Map<String, dynamic>> items) async {
    setState(() => _exporting = true);
    try {
      final choice =
          await showDialog<({MessageExportFormat format, bool share})>(
              context: context,
              builder: (c) => SimpleDialog(
                      title: const Text('Export message history'),
                      children: [
                        const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                                'Includes all local message text (including any pending save), times, radio identifiers, recipients and delivery status. Choose where to save or share it. JSON preserves original text; CSV makes formula-like text safe for spreadsheets. Export does not delete history and cannot yet be imported into MeshScout.')),
                        for (final format in MessageExportFormat.values)
                          for (final share in [false, true])
                            SimpleDialogOption(
                                onPressed: () => Navigator.pop(
                                    c, (format: format, share: share)),
                                child: Text(
                                    '${share ? "Share" : "Save"} ${format.name.toUpperCase()}')),
                      ]));
      if (choice == null) {
        return;
      }
      final done = await MessageExportService()
          .send(items, choice.format, share: choice.share);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(done
                ? (choice.share ? 'Share menu opened' : 'Message history saved')
                : 'Save cancelled')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Message export failed. Try another destination.')));
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }
}
