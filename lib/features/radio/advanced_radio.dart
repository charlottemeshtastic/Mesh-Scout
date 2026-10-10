import 'diagnostics.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../common/mesh_data.dart';
import 'radio_notifier.dart';

List<int> publicKey(String value) {
  if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value)) {
    throw const FormatException(
        'Public key must contain 64 hexadecimal characters.');
  }
  return [
    for (var i = 0; i < 64; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16)
  ];
}

List<int> contactCommand(String key, String name, int type,
    {List<int> original = const []}) {
  final text = utf8.encode(name.trim());
  if (text.isEmpty ||
      text.length > 31 ||
      name.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      type < 1 ||
      type > 4) {
    throw const FormatException(
        'Use a name of 1–31 UTF-8 bytes and node type 1–4.');
  }
  final frame =
      original.length == 148 ? [...original] : List<int>.filled(148, 0);
  frame[0] = 9;
  frame.setRange(1, 33, publicKey(key));
  frame[33] = type;
  if (original.isEmpty) frame[35] = 255;
  frame.fillRange(100, 132, 0);
  frame.setRange(100, 100 + text.length, text);
  return frame;
}

List<int> channelCommand(int index, int capacity, String name, String secret) {
  final text = utf8.encode(name.trim());
  if (index < 0 ||
      index >= capacity ||
      capacity > 64 ||
      text.length > 31 ||
      text.isEmpty ||
      name.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
      !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(secret)) {
    throw const FormatException(
        'Choose an available slot, a 1–31 byte name and a 32-character hexadecimal key.');
  }
  return [
    32,
    index,
    ...text,
    ...List<int>.filled(32 - text.length, 0),
    for (var i = 0; i < 32; i += 2)
      int.parse(secret.substring(i, i + 2), radix: 16)
  ];
}

List<int> parametersCommand(double mhz, double khz, int sf, int cr,
    {bool? repeat}) {
  if (!mhz.isFinite ||
      !khz.isFinite ||
      mhz < 150 ||
      mhz > 2500 ||
      khz < 7 ||
      khz > 500 ||
      sf < 5 ||
      sf > 12 ||
      cr < 5 ||
      cr > 8) {
    throw const FormatException(
        'Firmware ranges: 150–2500 MHz, 7–500 kHz, SF 5–12, CR 5–8.');
  }
  final data = ByteData(10)
    ..setUint32(0, (mhz * 1000).round(), Endian.little)
    ..setUint32(4, (khz * 1000).round(), Endian.little)
    ..setUint8(8, sf)
    ..setUint8(9, cr);
  return [11, ...data.buffer.asUint8List(), if (repeat != null) repeat ? 1 : 0];
}

class AdvancedRadioScreen extends ConsumerStatefulWidget {
  const AdvancedRadioScreen({super.key});
  @override
  ConsumerState<AdvancedRadioScreen> createState() => _AdvancedRadioState();
}

class _AdvancedRadioState extends ConsumerState<AdvancedRadioScreen> {
  String notice = '';
  String? pendingKey;
  int? pendingToken;
  DateTime? requestedAt;
  bool busy = false;
  Future<void> run(List<int> command,
      {Set<int> replies = const {0}, bool refresh = false}) async {
    final radio = ref.read(radioProvider.notifier);
    if (busy || !radio.beginControls()) {
      setState(() => notice =
          'Connect the radio and wait for other operations to finish.');
      return;
    }
    if (command.length > radio.mtu - 3) {
      radio.endControls(radio.sessionToken);
      setState(() => notice = 'Bluetooth MTU is too small for this command. Reconnect and retry.');
      return;
    }
    final token = radio.sessionToken;
    setState(() {
      busy = true;
      notice = 'Waiting for companion…';
    });
    try {
      await radio.messageCommand(command, replies, control: true);
      if (mounted && token == radio.sessionToken && notice == 'Waiting for companion…') {
        setState(() => notice =
            'Companion accepted request. Remote requests need a reply to confirm success.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => notice =
            'Request failed or outcome uncertain. Reconnect before retrying.'); }
    } finally {
      radio.endControls(token);
      if (mounted) { setState(() => busy = false); }
    }
    if (refresh && token == radio.sessionToken) { await radio.refreshContacts(); }
  }

  Future<List<String>?> form(String title, List<String> labels,
          {List<String>? initial, bool secret = false}) =>
      showDialog<List<String>>(
          context: context,
          builder: (_) => _Fields(
              title: title, labels: labels, initial: initial, secret: secret));
  Future<void> guarded(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() => notice =
            e is FormatException ? e.message.toString() : 'Operation failed.'); }
    }
  }

  Future<void> editContact([MeshContact? c]) => guarded(() async {
        final values = await form(c == null ? 'Add contact' : 'Edit contact', [
          'Public key',
          'Name',
          'Type: 1 chat, 2 repeater, 3 room, 4 sensor'
        ], initial: [
          c?.key ?? '',
          c?.name ?? '',
          '${c?.type ?? 1}'
        ]);
        if (values == null) { return; }
        await run(
            contactCommand(values[0], values[1], int.parse(values[2]),
                original: c?.frame ?? const []),
            refresh: true);
      });
  Future<void> remote(MeshContact c, int command) => guarded(() async {
        final key = publicKey(c.key);
        List<int> frame;
        if (command == 26) {
          final values = await form(
              'Log in to ${c.name}', ['Repeater password (never saved)'],
              secret: true);
          if (values == null) { return; }
          final password = utf8.encode(values.first);
          if (password.isEmpty ||
              password.length > 64 ||
              values.first.contains('\u0000')) {
            throw const FormatException('Use a password of 1–64 UTF-8 bytes.'); }
          frame = [26, ...key, ...password];
        } else if (command == 2) {
          final values = await form('Repeater CLI command',
              ['Command (may change remote configuration)']);
          if (values == null) { return; }
          final body = utf8.encode(values.first);
          if (body.isEmpty ||
              body.length > 133 ||
              values.first.contains('\u0000')) {
            throw const FormatException('Use a command of 1–133 UTF-8 bytes.'); }
          final time = ByteData(4)
            ..setUint32(0, DateTime.now().millisecondsSinceEpoch ~/ 1000,
                Endian.little);
          frame = [
            2,
            1,
            0,
            ...time.buffer.asUint8List(),
            ...key.take(6),
            ...body
          ];
        } else {
          frame = switch (command) {
            52 => [52, 0, ...key],
            39 => [39, 0, 0, 0, ...key],
            _ => [command, ...key]
          };
        }
        requestedAt = DateTime.now();
        pendingKey = c.key.substring(0, 12);
        pendingToken = ref.read(radioProvider.notifier).sessionToken;
        await run(frame, replies: const {6});
      });
  @override
  Widget build(BuildContext buildContext) {
    final state = ref.watch(radioProvider);
    ref.listen(radioProvider.select((s) => s.remoteEvent), (_, next) {
      if (next == null ||
          next.length < 8 ||
          pendingToken != ref.read(radioProvider.notifier).sessionToken) { return; }
      final prefix = next
          .sublist(2, 8)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (prefix != pendingKey ||
          state.phase != RadioPhase.ready ||
          requestedAt == null ||
          DateTime.now().difference(requestedAt!).inSeconds > 60) { return; }
      String details;
      try {
        details = next.first == 0x8b
            ? telemetryDescription(next.sublist(8))
            : next.first == 0x8d
                ? pathDescription(next)
                : next
                    .skip(8)
                    .map((b) => b.toRadixString(16).padLeft(2, '0'))
                    .join(' ');
      } on FormatException {
        setState(() => notice = 'Malformed remote response; result unknown.');
        return;
      }
      setState(() => notice = '${switch (next.first) {
            0x85 => "Login accepted",
            0x86 => "Login rejected",
            0x87 => "Status response received: node reachable now",
            0x8b => "Telemetry response received",
            0x8d => "Path response received",
            _ => "Response"
          }} at ${DateTime.now().toLocal()}. Payload (firmware format): $details');
    });
    final ready = !busy &&
        state.phase == RadioPhase.ready &&
        !state.controlsBusy &&
        !state.syncing &&
        !state.messagingBusy &&
        !state.channelsLoading;
    return Scaffold(
        appBar: AppBar(title: const Text('Contacts, channels & diagnostics')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          if (busy) const LinearProgressIndicator(),
          if (notice.isNotEmpty) SelectableText(notice),
          const Text(
              'Changes are sent only when you press Apply. A companion acceptance is not a remote-node response. Repeater permissions depend on its owner and firmware. Fetch CLI replies in Messages.'),
          FilledButton(
              onPressed: ready ? editContact : null,
              child: const Text('Add contact')),
          OutlinedButton(
              onPressed: () => guarded(() async {
                    final content = jsonEncode({
                      'format': 'meshscout-contacts',
                      'version': 1,
                      'contacts': [
                        for (final c in state.contacts)
                          {
                            'key': c.key,
                            'name': c.name,
                            'type': c.type,
                            'frame': c.frame
                          }
                      ]
                    });
                    await const MethodChannel('org.meshscout/files')
                        .invokeMethod<bool>('save', {
                      'name':
                          'MeshScout-${DateTime.now().millisecondsSinceEpoch}.json',
                      'mime': 'application/json',
                      'content': content
                    });
                  }),
              child: const Text('Export contacts')),
          OutlinedButton(
              onPressed: ready
                  ? () => guarded(() async {
                        final text =
                            await const MethodChannel('org.meshscout/files')
                                .invokeMethod<String>('openBackup');
                        if (text == null) { return; }
                        final data = jsonDecode(text) as Map<String, dynamic>;
                        if (data['format'] != 'meshscout-contacts' ||
                            data['version'] != 1 ||
                            data['contacts'] is! List ||
                            (data['contacts'] as List).length > 100) {
                          throw const FormatException(
                              'Choose a MeshScout contact export with up to 100 contacts.'); }
                        final commands = <List<int>>[];
                        for (final value in data['contacts'] as List) {
                          final row = value as Map<String, dynamic>;
                          final raw = (row['frame'] as List?)?.cast<int>() ??
                              const <int>[];
                          if (raw.isNotEmpty &&
                              (raw.length != 148 ||
                                  raw.any((v) => v < 0 || v > 255) ||
                                  MeshContact.parse([3, ...raw.skip(1)]).key !=
                                      row['key'])) {
                            throw const FormatException(
                                'Invalid contact data.'); }
                          commands.add(contactCommand(row['key'] as String,
                              row['name'] as String, row['type'] as int,
                              original: raw));
                        }
                        if (!mounted) { return; }
                        final yes = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                                    title: Text(
                                        'Import ${commands.length} contacts?'),
                                    content: const Text(
                                        'Existing public keys are updated. Other contacts are retained.'),
                                    actions: [
                                      TextButton(
                                          onPressed: () => Navigator.pop(c),
                                          child: const Text('Cancel')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(c, true),
                                          child: const Text('Import'))
                                    ]));
                        if (yes != true) { return; }
                        for (final command in commands) {
                          await run(command);
                          if (!notice.startsWith('Companion accepted')) break;
                        }
                        await ref
                            .read(radioProvider.notifier)
                            .refreshContacts();
                      })
                  : null,
              child: const Text('Import contacts')),
          const Divider(),
          Text(
              'Newly heard nodes (${state.heard.length}) — firmware must report discovery advertisements.'),
          for (final c in state.heard)
            ListTile(
                title: Text(c.name),
                subtitle: Text(c.typeLabel),
                trailing: TextButton(
                    onPressed: ready
                        ? () => run(
                            contactCommand(c.key, c.name, c.type,
                                original: c.frame),
                            refresh: true)
                        : null,
                    child: const Text('Import'))),
          const Divider(),
          OutlinedButton(
              onPressed: ready
                  ? () => guarded(() async {
                        final values = await form('Create or replace channel', [
                          'Slot index',
                          'Name',
                          '128-bit key: 32 hex characters (leave empty to generate)'
                        ]);
                        if (values == null) { return; }
                        final generated = List.generate(
                                16, (_) => Random.secure().nextInt(256))
                            .map((b) => b.toRadixString(16).padLeft(2, '0'))
                            .join();
                        final secret =
                            values[2].isEmpty ? generated : values[2];
                        final command = channelCommand(
                            int.parse(values[0]),
                            ref.read(radioProvider.notifier).channelCapacity,
                            values[1],
                            secret);
                        if (!mounted) { return; }
                        final yes = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                                    title: const Text(
                                        'Replace this channel slot?'),
                                    content: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Text(
                                              'Keep this key securely to configure other radios. Existing keys are never read or exported.'),
                                          SelectableText(secret)
                                        ]),
                                    actions: [
                                      TextButton(
                                          onPressed: () => Navigator.pop(c),
                                          child: const Text('Cancel')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(c, true),
                                          child: const Text('Apply'))
                                    ]));
                        if (yes == true) {
                          await run(command);
                          await ref
                              .read(radioProvider.notifier)
                              .refreshChannels();
                        }
                      })
                  : null,
              child: const Text('Create / edit channel and key')),
          OutlinedButton(
              onPressed: ready
                  ? () => guarded(() async {
                        final values = await form('Advanced radio settings', [
                          'Frequency MHz',
                          'Bandwidth kHz',
                          'Spreading factor',
                          'Coding rate',
                          'Client repeat: 0 off / 1 on (firmware 9+)'
                        ], initial: const [
                          '',
                          '',
                          '7',
                          '5',
                          '0'
                        ]);
                        if (values == null) { return; }
                        if (!['0', '1'].contains(values[4])) {
                          throw const FormatException('Client repeat must be 0 or 1.');
                        }
                        final command = parametersCommand(
                            double.parse(values[0]),
                            double.parse(values[1]),
                            int.parse(values[2]),
                            int.parse(values[3]), repeat: values[4] == '1');
                        if (!mounted) { return; }
                        final yes = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                                    title:
                                        const Text('Apply radio parameters?'),
                                    content: const Text(
                                        'Use values permitted for your radio and region. Client repeat is set to the value entered. These must match your mesh. A mismatch can stop communication.'),
                                    actions: [
                                      TextButton(
                                          onPressed: () => Navigator.pop(c),
                                          child: const Text('Cancel')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(c, true),
                                          child: const Text('Apply'))
                                    ]));
                        if (yes == true) { await run(command); }
                      })
                  : null,
              child: const Text('Frequency, bandwidth, SF and CR')),
          const Divider(),
          for (final c in state.contacts)
            ExpansionTile(
                title: Text(c.name),
                subtitle: Text(c.typeLabel),
                children: [
                  Wrap(children: [
                    TextButton(
                        onPressed: ready ? () => editContact(c) : null,
                        child: const Text('Edit')),
                    TextButton(
                        onPressed: ready
                            ? () => guarded(() async {
                                  final yes = await showDialog<bool>(
                                      context: context,
                                      builder: (d) => AlertDialog(
                                              title: Text('Delete ${c.name}?'),
                                              actions: [
                                                TextButton(
                                                    onPressed: () =>
                                                        Navigator.pop(d),
                                                    child:
                                                        const Text('Cancel')),
                                                FilledButton(
                                                    onPressed: () =>
                                                        Navigator.pop(d, true),
                                                    child: const Text('Delete'))
                                              ]));
                                  if (yes == true) {
                                    await run([15, ...publicKey(c.key)],
                                        refresh: true); }
                                })
                            : null,
                        child: const Text('Delete')),
                    TextButton(
                        onPressed: ready ? () => remote(c, 52) : null,
                        child: const Text('Discover path')),
                    TextButton(
                        onPressed: ready ? () => remote(c, 27) : null,
                        child: const Text('Check reachability / status')),
                    TextButton(
                        onPressed: ready ? () => remote(c, 39) : null,
                        child: const Text('Request telemetry')),
                    if (c.type == 2) ...[
                      TextButton(
                          onPressed: ready ? () => remote(c, 26) : null,
                          child: const Text('Log in')),
                      TextButton(
                          onPressed: ready ? () => remote(c, 2) : null,
                          child: const Text('Send CLI command'))
                    ]
                  ])
                ]),
          const Text(
              'A missing reply leaves reachability unknown. Paths show repeater hashes and standard Cayenne telemetry is decoded. Status and unknown telemetry fields remain raw firmware bytes.'),
        ]));
  }
}

class _Fields extends StatefulWidget {
  const _Fields(
      {required this.title,
      required this.labels,
      this.initial,
      this.secret = false});
  final String title;
  final List<String> labels;
  final List<String>? initial;
  final bool secret;
  @override
  State<_Fields> createState() => _FieldsState();
}

class _FieldsState extends State<_Fields> {
  late final fields = [
    for (var i = 0; i < widget.labels.length; i++)
      TextEditingController(text: widget.initial?[i] ?? '')
  ];
  @override
  void dispose() {
    for (final f in fields) {
      f.clear();
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < fields.length; i++)
              TextField(
                  controller: fields[i],
                  obscureText: widget.secret,
                  decoration: InputDecoration(labelText: widget.labels[i]))
          ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () =>
                    Navigator.pop(context, [for (final f in fields) f.text]),
                child: const Text('Apply'))
          ]);
}
