import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ble_service.dart';

final bleServiceProvider =
    Provider<BleService>((ref) => throw UnimplementedError());
final radioTimerProvider = Provider<Timer Function(Duration, void Function())>(
  (ref) => Timer.new,
);
final radioProvider =
    NotifierProvider<RadioNotifier, RadioState>(RadioNotifier.new);

enum RadioPhase {
  idle,
  authorizing,
  scanning,
  connecting,
  identifying,
  ready,
  failed
}

class RadioState {
  const RadioState(
      {this.phase = RadioPhase.idle, this.devices = const [], this.failure});
  final RadioPhase phase;
  final List<RadioDevice> devices;
  final RadioFailure? failure;
  bool get busy => phase != RadioPhase.idle && phase != RadioPhase.failed;
}

/// Owns one foreground session. A generation invalidates every stale callback.
class RadioNotifier extends Notifier<RadioState> {
  StreamSubscription<RadioDevice>? _scan;
  StreamSubscription<RadioLink>? _link;
  StreamSubscription<List<int>>? _notifications;
  Timer? _deadline;
  Completer<List<int>>? _response;
  int? _expected;
  int _generation = 0;
  bool _disposed = false;
  final _cancelOperations = <void Function()>{};

  @override
  RadioState build() {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_cleanup());
    });
    return const RadioState();
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  BleService get _service => ref.read(bleServiceProvider);

  Future<void> scan() async {
    if (state.busy) return;
    final generation = ++_generation;
    state = const RadioState(phase: RadioPhase.authorizing);
    try {
      await _service.authorize();
      if (!_current(generation)) return;
      state = const RadioState(phase: RadioPhase.scanning);
      _scan = _service.scan().listen((device) {
        if (!_current(generation)) return;
        final devices = {
          for (final d in state.devices) d.id: d,
          device.id: device
        };
        state = RadioState(
            phase: RadioPhase.scanning,
            devices: List.unmodifiable(devices.values));
      }, onError: (Object e) => unawaited(_fail(generation, e)));
      _deadline = ref.read(radioTimerProvider)(
          const Duration(seconds: 10), () => unawaited(stopScan()));
    } catch (e) {
      await _fail(generation, e);
    }
  }

  Future<void> stopScan() async {
    if (state.phase != RadioPhase.scanning) return;
    final generation = ++_generation;
    _deadline?.cancel();
    await _scan?.cancel();
    _scan = null;
    if (_current(generation)) state = RadioState(devices: state.devices);
  }

  Future<void> connect(RadioDevice device) async {
    if (state.phase != RadioPhase.idle ||
        !state.devices.any((d) => d.id == device.id)) {
      return;
    }
    final generation = ++_generation;
    state = const RadioState(phase: RadioPhase.connecting);
    try {
      await _service.authorize();
      if (!_current(generation)) return;
      _deadline = ref.read(radioTimerProvider)(
          const Duration(seconds: 20),
          () => unawaited(
              _fail(generation, const RadioException(RadioFailure.transport))));
      _link = _service.connect(device.id).listen((link) {
        if (!_current(generation)) return;
        if (link == RadioLink.connected &&
            state.phase == RadioPhase.connecting) {
          state = const RadioState(phase: RadioPhase.identifying);
          unawaited(_identify(generation, device.id));
        } else if (link == RadioLink.disconnected) {
          unawaited(
              _fail(generation, const RadioException(RadioFailure.transport)));
        }
      },
          onError: (Object e) => unawaited(_fail(generation, e)),
          onDone: () => unawaited(
              _fail(generation, const RadioException(RadioFailure.transport))));
    } catch (e) {
      await _fail(generation, e);
    }
  }

  Future<void> _identify(int generation, String id) async {
    try {
      await _withTimeout(_service.discover(id), const Duration(seconds: 5));
      if (!_current(generation)) return;
      _notifications = _service.notifications(id).listen((bytes) {
        if (!_current(generation) || bytes.isEmpty) return;
        final minimum = _expected == 5 ? 58 : 80;
        if (bytes.first == _expected && bytes.length >= minimum) {
          final response = _response;
          if (response != null && !response.isCompleted) {
            response.complete(bytes);
          }
        }
      }, onError: (Object e) => unawaited(_fail(generation, e)));
      // APP_START is harmless and retried once if notification setup races it.
      await _exchange(generation, id, appStart, 5);
      if (!_current(generation)) return;
      final info = await _exchange(generation, id, deviceQuery, 13);
      if (!_current(generation)) return;
      if (info[1] < 3) {
        throw const RadioException(RadioFailure.protocol);
      }
      _deadline?.cancel();
      state = const RadioState(phase: RadioPhase.ready);
    } catch (e) {
      await _fail(generation, e);
    }
  }

  Future<List<int>> _exchange(
      int generation, String id, List<int> command, int expected) async {
    _expected = expected;
    final response = Completer<List<int>>();
    _response = response;
    // Observe cancellation before sending and after each bounded operation.
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!_current(generation)) {
        throw const RadioException(RadioFailure.transport);
      }
      await _withTimeout(
          _service.write(id, command), const Duration(seconds: 3));
      try {
        return await _withTimeout(response.future, const Duration(seconds: 2));
      } on TimeoutException {
        if (attempt == 1) {
          throw const RadioException(RadioFailure.protocol);
        }
      }
    }
    throw const RadioException(RadioFailure.protocol);
  }

  /// Bounded operations share the injected scheduler and can be cancelled.
  Future<T> _withTimeout<T>(Future<T> operation, Duration duration) {
    final result = Completer<T>();
    final timer = ref.read(radioTimerProvider)(duration, () {
      if (!result.isCompleted) {
        result.completeError(TimeoutException('Bluetooth operation timed out'));
      }
    });
    void cancel() {
      timer.cancel();
      if (!result.isCompleted) {
        result.completeError(const RadioException(RadioFailure.transport));
      }
    }

    _cancelOperations.add(cancel);
    void finish() {
      timer.cancel();
      _cancelOperations.remove(cancel);
    }

    operation.then((value) {
      finish();
      if (!result.isCompleted) result.complete(value);
    }, onError: (Object error, StackTrace stack) {
      finish();
      if (!result.isCompleted) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<void> _fail(int generation, Object error) async {
    if (!_current(generation)) return;
    final cleanupGeneration = ++_generation;
    await _cleanup();
    if (_current(cleanupGeneration)) {
      state = RadioState(
          phase: RadioPhase.failed,
          failure:
              error is RadioException ? error.failure : RadioFailure.transport);
    }
  }

  Future<void> disconnect() async {
    final generation = ++_generation;
    final failure = await _cleanup();
    if (_current(generation)) {
      state = failure == null
          ? const RadioState()
          : RadioState(phase: RadioPhase.failed, failure: failure);
    }
  }

  Future<RadioFailure?> _cleanup() async {
    _deadline?.cancel();
    final cancellations = _cancelOperations.toList();
    _cancelOperations.clear();
    for (final cancel in cancellations) {
      cancel();
    }
    final scan = _scan;
    final link = _link;
    final notifications = _notifications;
    _scan = null;
    _link = null;
    _notifications = null;
    _expected = null;
    _response = null;
    RadioFailure? failure;
    for (final subscription in <StreamSubscription<Object>?>[
      scan,
      notifications,
      link
    ]) {
      try {
        await subscription?.cancel();
      } catch (_) {
        failure = RadioFailure.transport;
      }
    }
    // Attempt every cancellation even when one plugin cleanup fails.
    return failure;
  }

  Future<void> openSettings() async {
    try {
      await _service.openSettings();
    } catch (e) {
      await _fail(_generation, e);
    }
  }
}
