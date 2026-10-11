import 'package:flutter/material.dart';
import 'radio_notifier.dart';

/// A bounded live view: receptions are evidence of local RF activity, not a map.
class ObservationPanel extends StatelessWidget {
  const ObservationPanel(
      {required this.state, required this.actions, super.key});
  final RadioState state;
  final RadioNotifier actions;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text('Live LoRa observations',
              style: Theme.of(context).textTheme.titleLarge),
          const Text(
              'Listen for receptions reported by the companion radio. Message contents are discarded. This live list stays in memory. Start Mapping on Map to save GPS-associated receptions.'),
          if (state.phase == RadioPhase.ready)
            FilledButton(
              onPressed: state.collecting
                  ? actions.stopCollection
                  : actions.startCollection,
              child: Text(
                  state.collecting ? 'Stop collecting' : 'Start collecting'),
            ),
          Text(
              '${state.receivedCount} receptions · ${state.observations.length} kept · ${state.malformedCount} malformed reports skipped'),
          if (state.receivedCount > 0 || state.malformedCount > 0)
            TextButton(
              onPressed: actions.clearObservations,
              child: const Text('Clear observations'),
            ),
          if (state.observations.isEmpty)
            Text(state.collecting
                ? 'Waiting for RF reception reports. Silence does not mean there is no coverage; the firmware may not provide these reports.'
                : 'Collection is stopped. Connect a radio and start collecting.'),
          const Text(
              'Latest 20 shown; up to 200 kept in memory. A new scan clears this session. Receptions are not proof of delivery or sender identity.'),
          for (final observation in state.observations.take(20))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                  'LoRa RSSI ${observation.rssiDbm} dBm · SNR ${observation.snrDb.toStringAsFixed(2)} dB'),
              subtitle: Text(
                  '${observation.receivedAt.toIso8601String()} · ${observation.isFlood ? "Flood" : "Direct"} · ${_packetLabel(observation.payloadType)}'),
            ),
        ],
      );
}

String _packetLabel(int type) => switch (type) {
      0 => 'Request',
      1 => 'Response',
      2 => 'Message',
      3 => 'Acknowledgment',
      4 => 'Advertisement',
      5 => 'Channel message',
      6 => 'Channel data',
      7 => 'Anonymous request',
      8 => 'Route update',
      9 => 'Trace',
      10 => 'Multipart packet',
      11 => 'Control packet',
      15 => 'Custom packet',
      _ => 'Unknown packet',
    };
