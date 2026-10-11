import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../common/mesh_data.dart';
import '../radio/radio_notifier.dart';
import '../messages/messages.dart';
import '../radio/advanced_radio.dart';
import 'repeater_details.dart';

class NodesScreen extends ConsumerStatefulWidget {
  const NodesScreen({super.key});
  @override
  ConsumerState<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends ConsumerState<NodesScreen> {
  String _query = '';
  bool _repeatersOnly = false;
  @override
  Widget build(BuildContext context) {
    final radio = ref.watch(radioProvider);
    final contacts = radio.contacts
        .where(
          (c) =>
              (!_repeatersOnly || c.type == 2) &&
              ('${c.name} ${c.key}'.toLowerCase().contains(
                    _query.toLowerCase(),
                  )),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Nodes', style: Theme.of(context).textTheme.headlineSmall),
        const Text(
          'Contacts stored on your companion radio. A saved contact does not prove current reachability.',
        ),
        OutlinedButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const AdvancedRadioScreen(),
            ),
          ),
          child: const Text('Manage contacts, channels and diagnostics'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: '/messages'),
              builder: (_) => const MessagesScreen(),
            ),
          ),
          icon: const Icon(Icons.message_outlined),
          label: const Text('Messages'),
        ),
        FilledButton.icon(
          onPressed: radio.phase == RadioPhase.ready &&
                  !radio.syncing &&
                  !radio.messagingBusy
              ? () async => ref.read(radioProvider.notifier).refreshContacts()
              : null,
          icon: const Icon(Icons.sync),
          label: Text(
            radio.syncing ? 'Loading contacts…' : 'Refresh from radio',
          ),
        ),
        if (radio.syncing) const LinearProgressIndicator(),
        if (radio.phase != RadioPhase.ready)
          const Text('Connect a MeshCore companion to refresh contacts.'),
        if (radio.contactMessage != null) Text(radio.contactMessage!),
        if (radio.syncedAt != null)
          Text(
            'Last loaded: ${radio.syncedAt!.toLocal().toString().split('.').first}',
          ),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search names or public keys',
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        SwitchListTile(
          title: const Text('Repeaters only'),
          value: _repeatersOnly,
          onChanged: (value) => setState(() => _repeatersOnly = value),
        ),
        Text('${contacts.length} contacts'),
        if (contacts.isEmpty && !radio.syncing && !radio.messagingBusy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No matching contacts. Refresh after connecting your radio.',
            ),
          ),
        for (final contact in contacts)
          ListTile(
            leading: Icon(
              contact.type == 2 ? Icons.cell_tower : Icons.person_outline,
            ),
            title: Text(
              contact.name.isEmpty ? 'Unnamed contact' : contact.name,
            ),
            subtitle: Text(
              '${contact.typeLabel} · ${contact.key.substring(0, 12)}…',
            ),
            onTap: () => contact.type == 2
                ? Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RepeaterDetailsScreen(contact: contact)))
                : _details(context, contact),
          ),
      ],
    );
  }

  void _details(BuildContext context, MeshContact contact) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(contact.name.isEmpty ? 'Unnamed contact' : contact.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(contact.typeLabel),
              const SizedBox(height: 8),
              const Text('Public key'),
              SelectableText(contact.key),
              const SizedBox(height: 8),
              Text(
                contact.lastAdvert == null
                    ? 'No advertisement timestamp'
                    : 'Advertised: ${contact.lastAdvert!.toLocal().toString().split('.').first}',
              ),
              Text(
                contact.latitude == null
                    ? 'No advertised location'
                    : 'Advertised location: ${contact.latitude!.toStringAsFixed(6)}, ${contact.longitude!.toStringAsFixed(6)}',
              ),
              const SizedBox(height: 8),
              const Text(
                'This is radio-stored information, not a live signal or coverage measurement.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
