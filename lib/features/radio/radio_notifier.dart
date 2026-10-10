import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'ble_service.dart';

final bleServiceProvider =
    Provider<BleService>((ref) => throw UnimplementedError());
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

/// Owns one radio session. A generation invalidates every stale callback.
class RadioNotifier extends Notifier<RadioState> {
  StreamSubscription<RadioDevice>? _scan;
  StreamSubscription<RadioLink>? _link;
  StreamSubscription<List<int>>? _notifications;
  Timer? _deadline;
  Completer<List<int>>? _response;
  int? _expected;
  int _generation = 0;
  bool _disposed = false;

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
      _deadline =
          Timer(const Duration(seconds: 10), () => unawaited(stopScan()));
    } catch (e) {
      await _fail(generation, e);
    }
  }

  Future<void> stopScan() async {
    if (state.phase != RadioPhase.scanning) return;
    final generation = ++_generation;
    _deadline?.cancel();
    try {
      await _scan?.cancel();
      if (!_current(generation)) return;
      _scan = null;
      state = RadioState(devices: state.devices);
    } catch (error) {
      await _fail(generation, error);
    }
  }

  Future<void> connect(RadioDevice device) async {
    if ((state.phase != RadioPhase.idle &&
            state.phase != RadioPhase.scanning) ||
        !state.devices.any((d) => d.id == device.id)) {
      return;
    }
    final generation = ++_generation;
    state = const RadioState(phase: RadioPhase.connecting);
    _deadline?.cancel();
    final scan = _scan;
    _scan = null;
    try {
      // Selecting a result ends scanning immediately, without its ten-second wait.
      await scan?.cancel();
      if (!_current(generation)) return;
      await _service.authorize();
      if (!_current(generation)) return;
      _deadline = Timer(
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
      await _service.discover(id).timeout(const Duration(seconds: 5));
      if (!_current(generation)) return;
      final mtu =
          await _service.negotiateMtu(id).timeout(const Duration(seconds: 5));
      if (!_current(generation)) return;
      if (mtu < minimumIdentificationMtu) {
        throw const RadioException(RadioFailure.protocol);
      }
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
      await _service.write(id, command).timeout(const Duration(seconds: 3));
      try {
        return await response.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        if (attempt == 1) {
          throw const RadioException(RadioFailure.protocol);
        }
      }
    }
    throw const RadioException(RadioFailure.protocol);
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

  Future<void> background() async {
    if (state.phase == RadioPhase.ready) return;
    if (state.phase == RadioPhase.scanning) {
      await stopScan();
    } else if (state.phase == RadioPhase.authorizing ||
        state.phase == RadioPhase.connecting ||
        state.phase == RadioPhase.identifying) {
      await disconnect();
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
