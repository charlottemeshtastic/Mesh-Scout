import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup/backup.dart';
import '../radio/radio_notifier.dart';
import '../settings/field_settings.dart';
import 'map_layers.dart';
import 'mapping_notifier.dart';
import 'mapping_service.dart';

String pingCell(GpsPoint point) =>
    '${(point.latitude / coverageCellDegrees).floor()}:${(point.longitude / coverageCellDegrees).floor()}';

bool recentlyMeasured(GpsPoint point, Iterable<MappingSession> sessions,
    {required DateTime now, required int days, required String preset}) {
  final cutoff = now.subtract(Duration(days: days));
  for (final session in sessions) {
    if (session.planned || session.preset != preset) continue;
    for (final o in session.observations) {
      if (!o.time.isAfter(now) &&
          !o.time.isBefore(cutoff) &&
          pingCell(o.point) == pingCell(point)) return true;
    }
  }
  return false;
}

class SmartPingState {
  const SmartPingState(
      {this.busy = false,
      this.sent = 0,
      this.held = 0,
      this.notice = 'Discovery pings are off.'});
  final bool busy;
  final int sent, held;
  final String notice;
}

final smartPingProvider =
    NotifierProvider<SmartPing, SmartPingState>(SmartPing.new);
final smartPingTickProvider = Provider<Duration?>((ref) => null);

class SmartPing extends Notifier<SmartPingState> {
  Timer? _timer;
  DateTime? _lastAttempt;
  final _pingedCells = <String, DateTime>{};
  bool _foreground = true;
  int _generation = 0;
  int? _failedToken;
  @override
  SmartPingState build() {
    final interval = ref.read(smartPingTickProvider);
    if (interval != null)
      _timer = Timer.periodic(interval, (_) => unawaited(send()));
    ref.listen(fieldSettingsProvider.select((s) => s.smartPing), (_, enabled) {
      _generation++;
      if (!enabled)
        state = SmartPingState(
            busy: state.busy,
            sent: state.sent,
            held: state.held,
            notice:
                'Automatic pings stopped. A command already sent to the radio cannot be withdrawn.');
    });
    ref.listen(mappingProvider.select((s) => s.recording), (before, after) {
      _generation++;
      if (after && before != true) {
        _lastAttempt = null;
        _pingedCells.clear();
        _failedToken = null;
        state = const SmartPingState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _timer?.cancel();
    });
    return const SmartPingState();
  }

  void foreground(bool active) {
    _foreground = active;
    if (!active) _generation++;
  }

  Future<void> send({bool manual = false}) async {
    final settings = ref.read(fieldSettingsProvider),
        mapping = ref.read(mappingProvider),
        radio = ref.read(radioProvider);
    final now = ref.read(mappingClockProvider)();
    if (state.busy ||
        !_foreground ||
        ref.read(maintenanceProvider) ||
        !mapping.recording ||
        mapping.busy ||
        mapping.points.isEmpty ||
        !manual && !settings.smartPing ||
        radio.phase != RadioPhase.ready ||
        radio.syncing ||
        radio.messagingBusy ||
        radio.controlsBusy ||
        radio.channelsLoading) return;
    final token = ref.read(radioProvider.notifier).sessionToken;
    if (_failedToken == token && !manual) return;
    // Manual sends also respect the minimum interval; switching modes cannot
    // create a burst or retry an uncertain send automatically.
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < Duration(minutes: settings.pingMinutes))
      return;
    final point = mapping.points.last;
    final age = now.difference(point.time);
    if (!point.valid ||
        point.accuracy > 50 ||
        age.isNegative ||
        age > const Duration(seconds: 15) ||
        radio.preset == null) {
      state = SmartPingState(
          sent: state.sent,
          held: state.held,
          notice:
              'Waiting for a fresh GPS fix (within 15 seconds / 50 m) and a known radio preset.');
      return;
    }
    _lastAttempt = now;
    final cell = pingCell(point);
    final recentSend = _pingedCells[cell];
    final measured = recentlyMeasured(
        point,
        [
          ...mapping.sessions,
          MappingSession(
              id: 'current',
              started: now,
              ended: now,
              points: const [],
              observations: mapping.observations,
              preset: radio.preset!.key),
        ],
        now: now,
        days: settings.pingDays,
        preset: radio.preset!.key);
    if (!manual &&
        (measured ||
            recentSend != null &&
                now.difference(recentSend) < const Duration(minutes: 10))) {
      state = SmartPingState(
          sent: state.sent,
          held: state.held + 1,
          notice: measured
              ? 'Ping held: this cell has recent measured coverage on this preset.'
              : 'Ping held: this cell was pinged within 10 minutes.');
      return;
    }
    final generation = _generation, sent = state.sent, held = state.held;
    state = SmartPingState(
        busy: true,
        sent: sent,
        held: held,
        notice: 'Sending a zero-hop discovery advertisement…');
    try {
      // MeshCore CMD_SEND_SELF_ADVERT, zero-hop. Do not change the radio's
      // advertised location, flood mode or channel configuration.
      await ref
          .read(radioProvider.notifier)
          .messageCommand(const [7, 0], const {0});
      _pingedCells[cell] = now;
      if (_pingedCells.length > 1000)
        _pingedCells.remove(_pingedCells.keys.first);
      if (ref.mounted)
        state = SmartPingState(
            sent: sent + 1,
            held: held,
            notice: generation == _generation
                ? 'Radio accepted the discovery ping. Reception or two-way coverage is not confirmed.'
                : 'Ping command completed; automatic pinging remains stopped or paused.');
    } catch (_) {
      _failedToken = token;
      if (ref.mounted)
        state = SmartPingState(
            sent: sent,
            held: held,
            notice:
                'Ping result unknown. Automatic pings paused until reconnect; no automatic resend.');
    }
  }
}

class SmartPingControls extends ConsumerWidget {
  const SmartPingControls({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(fieldSettingsProvider),
        state = ref.watch(smartPingProvider);
    final mapping = ref.watch(mappingProvider),
        radio = ref.watch(radioProvider);
    final update = ref.read(fieldSettingsProvider.notifier).update;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Divider(),
      SwitchListTile(
          title: const Text('Smart discovery pinging'),
          value: settings.smartPing,
          subtitle: const Text(
              'Opt-in zero-hop advertisements while recording with the app open. Skips cells measured recently on the same preset. Pings do not create coverage measurements. Uses the radio’s existing advertised name and location policy.'),
          onChanged: (v) => update((s) => s.copyWith(smartPing: v))),
      Wrap(spacing: 12, children: [
        DropdownButton<int>(
            value: settings.pingMinutes,
            hint: const Text('Ping interval'),
            items: [
              for (final m in const [2, 5, 10])
                DropdownMenuItem(value: m, child: Text('Every $m min'))
            ],
            onChanged: (v) {
              if (v != null) update((s) => s.copyWith(pingMinutes: v));
            }),
        DropdownButton<int>(
            value: settings.pingDays,
            hint: const Text('Coverage age'),
            items: [
              for (final d in const [7, 14, 30, 90])
                DropdownMenuItem(value: d, child: Text('Coverage: $d days'))
            ],
            onChanged: (v) {
              if (v != null) update((s) => s.copyWith(pingDays: v));
            }),
      ]),
      OutlinedButton(
          onPressed: mapping.recording &&
                  radio.phase == RadioPhase.ready &&
                  !state.busy
              ? () => ref.read(smartPingProvider.notifier).send(manual: true)
              : null,
          child: const Text('Send discovery ping now')),
      Text('${state.sent} accepted · ${state.held} held'),
      Text(state.notice),
    ]);
  }
}
