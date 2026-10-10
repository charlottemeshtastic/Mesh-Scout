import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../radio/radio_notifier.dart';

abstract interface class AlertService {
  Future<bool> load();
  Future<bool> configure(bool enabled);
  Future<void> waiting();
  Future<void> clear();
}

class SilentAlerts implements AlertService {
  @override
  Future<bool> load() async => false;
  @override
  Future<bool> configure(bool enabled) async => false;
  @override
  Future<void> waiting() async {}
  @override
  Future<void> clear() async {}
}

final alertServiceProvider = Provider<AlertService>((ref) => SilentAlerts());
final messageAlertsProvider =
    NotifierProvider<MessageAlerts, AlertState>(MessageAlerts.new);

class AlertState {
  const AlertState({this.enabled = false, this.busy = false, this.notice});
  final bool enabled, busy;
  final String? notice;
}

class MessageAlerts extends Notifier<AlertState> {
  Future<void> _pending = Future.value();
  bool _initialized = false;
  @override
  AlertState build() {
    ref.listen(radioProvider.select((s) => s.messageEvent), (_, bytes) {
      if (state.enabled &&
          bytes != null &&
          bytes.length == 1 &&
          bytes.first == 0x83) {
        _enqueue(() => ref.read(alertServiceProvider).waiting());
      }
    });
    ref.listen(radioProvider.select((s) => s.phase), (_, phase) {
      if (phase != RadioPhase.ready) {
        _enqueue(() => ref.read(alertServiceProvider).clear());
      }
    });
    return const AlertState();
  }

  void _enqueue(Future<void> Function() operation) {
    _pending = _pending.then((_) async {
      if (!ref.mounted) {
        return;
      }
      try {
        await operation();
      } catch (_) {
        if (ref.mounted) {
          state = AlertState(
              enabled: state.enabled,
              busy: state.busy,
              notice:
                  'Message alerts could not be updated. Check Android notification settings.');
        }
      }
    });
  }

  Future<void> initialize() async {
    if (_initialized || state.busy) {
      return;
    }
    _initialized = true;
    state = const AlertState(busy: true);
    try {
      final enabled = await ref.read(alertServiceProvider).load();
      if (ref.mounted) {
        state = AlertState(enabled: enabled);
      }
    } catch (_) {
      if (ref.mounted) {
        state =
            const AlertState(notice: 'Could not load message alert settings.');
      }
    }
  }

  Future<void> configure(bool enabled) async {
    if (state.busy) {
      return;
    }
    final previous = state.enabled;
    state = AlertState(enabled: previous, busy: true);
    try {
      await _pending;
      if (!ref.mounted) {
        return;
      }
      final allowed = await ref.read(alertServiceProvider).configure(enabled);
      if (ref.mounted) {
        state = AlertState(
            enabled: allowed,
            notice: enabled && !allowed
                ? 'Notifications are blocked. Allow MeshScout messages in Android notification settings.'
                : null);
      }
    } catch (_) {
      if (ref.mounted) {
        state = AlertState(
            enabled: previous,
            notice: 'Could not save message alert settings. Try again.');
      }
    }
  }
}
