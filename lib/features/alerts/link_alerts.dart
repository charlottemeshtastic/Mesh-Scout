import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../radio/radio_notifier.dart';
import '../settings/field_settings.dart';

/// Platform alert for an unexpected radio link loss.
abstract interface class LinkAlertService {
  /// Plays the link-lost alert for the radio named [name].
  Future<void> lost(String? name);

  /// Clears the alert after the radio reconnects.
  Future<void> restored();
}

class SilentLinkAlerts implements LinkAlertService {
  @override
  Future<void> lost(String? name) async {}
  @override
  Future<void> restored() async {}
}

final linkAlertServiceProvider =
    Provider<LinkAlertService>((ref) => SilentLinkAlerts());

final linkAlertsProvider =
    NotifierProvider<LinkAlerts, int>(LinkAlerts.new);

/// Counts unexpected radio drops and raises an alert for each one.
///
/// A drop is a ready radio moving to reconnecting or failed. A manual
/// disconnect moves to idle and never alerts.
class LinkAlerts extends Notifier<int> {
  Future<void> _pending = Future.value();
  bool _alerted = false;

  @override
  int build() {
    ref.listen(radioProvider.select((s) => s.phase), (previous, next) {
      if (isLinkLoss(previous, next)) {
        state = state + 1;
        if (ref.read(fieldSettingsProvider).disconnectAlert) {
          _alerted = true;
          final name = ref.read(radioProvider.notifier).preferred?.name;
          _enqueue(() => ref.read(linkAlertServiceProvider).lost(name));
        }
      } else if (next == RadioPhase.ready && _alerted) {
        _alerted = false;
        _enqueue(() => ref.read(linkAlertServiceProvider).restored());
      }
    });
    return 0;
  }

  void _enqueue(Future<void> Function() operation) {
    _pending = _pending.then((_) async {
      if (!ref.mounted) return;
      try {
        await operation();
      } catch (_) {
        // An unavailable alert channel must not affect the radio connection.
      }
    });
    unawaited(_pending);
  }
}

/// Whether moving from [previous] to [next] means an established link dropped.
bool isLinkLoss(RadioPhase? previous, RadioPhase next) =>
    previous == RadioPhase.ready &&
    (next == RadioPhase.reconnecting || next == RadioPhase.failed);
