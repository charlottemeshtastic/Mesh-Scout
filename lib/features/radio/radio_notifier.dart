import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../common/mesh_data.dart';
import 'ble_service.dart';

final bleServiceProvider = Provider<BleService>((ref) => throw UnimplementedError());
final reconnectDelayProvider = Provider<Duration Function(int)>((ref) =>
  (attempt) => Duration(seconds: [3, 6, 12, 24, 30][attempt - 1]));
final radioProvider = NotifierProvider<RadioNotifier, RadioState>(RadioNotifier.new);

enum RadioPhase { idle, authorizing, scanning, connecting, identifying, ready, reconnecting, failed }

class RadioState {
  const RadioState({this.phase = RadioPhase.idle, this.devices = const [],
    this.failure, this.contacts = const [], this.syncing = false,
    this.contactMessage, this.syncedAt, this.lastRx, this.autoReconnect = true,
    this.retryAttempt = 0});
  final RadioPhase phase;
  final List<RadioDevice> devices;
  final RadioFailure? failure;
  final List<MeshContact> contacts;
  final bool syncing;
  final String? contactMessage;
  final DateTime? syncedAt;
  final RxObservation? lastRx;
  final bool autoReconnect;
  final int retryAttempt;
  bool get busy => phase != RadioPhase.idle && phase != RadioPhase.failed;
  RadioState copyWith({RadioPhase? phase, List<RadioDevice>? devices,
    List<MeshContact>? contacts, bool? syncing, String? contactMessage,
    DateTime? syncedAt, RxObservation? lastRx, bool? autoReconnect, int? retryAttempt}) => RadioState(
      phase: phase ?? this.phase, devices: devices ?? this.devices,
      failure: failure, contacts: contacts ?? this.contacts,
      syncing: syncing ?? this.syncing, contactMessage: contactMessage,
      syncedAt: syncedAt ?? this.syncedAt, lastRx: lastRx ?? this.lastRx,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      retryAttempt: retryAttempt ?? this.retryAttempt);
}

class RadioNotifier extends Notifier<RadioState> {
  StreamSubscription<RadioDevice>? _scan;
  StreamSubscription<RadioLink>? _link;
  StreamSubscription<List<int>>? _notifications;
  Timer? _deadline;
  Timer? _retry;
  Timer? _contactDeadline;
  Completer<List<int>>? _response;
  int? _expected;
  int _generation = 0;
  bool _disposed = false;
  bool _autoReconnect = true;
  bool _identifiedBefore = false;
  int _attempt = 0;
  int _mtu = 0;
  RadioDevice? _target;
  Map<String, MeshContact>? _incoming;
  int? _contactCount;
  bool _syncFailed = false;
  BleService? _cachedService;
  BleService get _service => _cachedService ??= ref.read(bleServiceProvider);
  bool _current(int generation) => !_disposed && generation == _generation;
  RadioState _empty({RadioPhase phase = RadioPhase.idle, RadioFailure? failure}) =>
    RadioState(phase: phase, failure: failure, autoReconnect: _autoReconnect);

  @override
  RadioState build() {
    ref.onDispose(() {
      _disposed = true; _generation++; _retry?.cancel();
      unawaited(_cleanup());
    });
    return const RadioState();
  }

  Future<void> scan() async {
    if (state.busy) return;
    final generation = ++_generation;
    state = _empty(phase: RadioPhase.authorizing);
    try {
      await _service.authorize();
      if (!_current(generation)) return;
      state = _empty(phase: RadioPhase.scanning);
      _scan = _service.scan().listen((device) {
        if (!_current(generation)) return;
        final devices = {for (final d in state.devices) d.id: d, device.id: device};
        state = state.copyWith(devices: List.unmodifiable(devices.values));
      }, onError: (Object e) => unawaited(_fail(generation, e)));
      _deadline = Timer(const Duration(seconds: 10), () => unawaited(stopScan()));
    } catch (e) { await _fail(generation, e); }
  }

  Future<void> stopScan() async {
    if (state.phase != RadioPhase.scanning) return;
    final generation = ++_generation;
    _deadline?.cancel();
    try {
      await _scan?.cancel();
      if (!_current(generation)) return;
      _scan = null;
      state = state.copyWith(phase: RadioPhase.idle);
    } catch (e) { await _fail(generation, e); }
  }

  Future<void> connect(RadioDevice device) async {
    if ((state.phase != RadioPhase.idle && state.phase != RadioPhase.scanning) ||
        !state.devices.any((d) => d.id == device.id)) return;
    _target = device; _identifiedBefore = false; _attempt = 0;
    final generation = ++_generation;
    state = _empty(phase: RadioPhase.connecting);
    _deadline?.cancel();
    final scan = _scan; _scan = null;
    try {
      await scan?.cancel();
      if (!_current(generation)) return;
      await _service.authorize();
      if (!_current(generation)) return;
      _connectLink(generation, device.id);
    } catch (e) { await _fail(generation, e); }
  }

  void _connectLink(int generation, String id) {
    _deadline = Timer(const Duration(seconds: 20), () => unawaited(
      _fail(generation, const RadioException(RadioFailure.transport))));
    _link = _service.connect(id).listen((link) {
      if (!_current(generation)) return;
      if (link == RadioLink.connected && state.phase == RadioPhase.connecting) {
        state = state.copyWith(phase: RadioPhase.identifying);
        unawaited(_identify(generation, id));
      } else if (link == RadioLink.disconnected) {
        unawaited(_fail(generation, const RadioException(RadioFailure.transport)));
      }
    }, onError: (Object e) => unawaited(_fail(generation, e)),
      onDone: () => unawaited(_fail(generation, const RadioException(RadioFailure.transport))));
  }

  Future<void> _identify(int generation, String id) async {
    try {
      await _service.discover(id).timeout(const Duration(seconds: 5));
      if (!_current(generation)) return;
      _mtu = await _service.negotiateMtu(id).timeout(const Duration(seconds: 5));
      if (!_current(generation)) return;
      if (_mtu < minimumIdentificationMtu) throw const RadioException(RadioFailure.protocol);
      _notifications = _service.notifications(id).listen((bytes) {
        if (!_current(generation) || bytes.isEmpty) return;
        if (state.phase == RadioPhase.ready) _data(bytes);
        final minimum = _expected == 5 ? 58 : 80;
        if (bytes.first == _expected && bytes.length >= minimum) {
          final response = _response;
          if (response != null && !response.isCompleted) response.complete(bytes);
        }
      }, onError: (Object e) => unawaited(_fail(generation, e)));
      await _exchange(generation, id, appStart, 5);
      if (!_current(generation)) return;
      final info = await _exchange(generation, id, deviceQuery, 13);
      if (!_current(generation)) return;
      if (info[1] < 3) throw const RadioException(RadioFailure.protocol);
      _deadline?.cancel(); _expected = null; _response = null;
      _identifiedBefore = true; _attempt = 0; _syncFailed = false;
      state = state.copyWith(phase: RadioPhase.ready, retryAttempt: 0);
    } catch (e) { await _fail(generation, e); }
  }

  Future<List<int>> _exchange(int generation, String id, List<int> command, int expected) async {
    _expected = expected;
    final response = Completer<List<int>>(); _response = response;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!_current(generation)) throw const RadioException(RadioFailure.transport);
      await _service.write(id, command).timeout(const Duration(seconds: 3));
      try { return await response.future.timeout(const Duration(seconds: 2)); }
      on TimeoutException {
        if (attempt == 1) throw const RadioException(RadioFailure.protocol);
      }
    }
    throw const RadioException(RadioFailure.protocol);
  }

  Future<void> refreshContacts() async {
    if (state.phase != RadioPhase.ready || state.syncing || _target == null) return;
    if (_syncFailed) {
      state = state.copyWith(contactMessage: 'Reconnect before starting another contact sync.');
      return;
    }
    if (_mtu < 151) {
      state = state.copyWith(contactMessage: 'Radio Bluetooth MTU is too small for contacts. Reconnect and retry.');
      return;
    }
    final generation = _generation;
    _incoming = {}; _contactCount = null;
    state = state.copyWith(syncing: true);
    _contactDeadline = Timer(const Duration(seconds: 30), () {
      if (_current(generation) && state.syncing) _syncError('Contact sync timed out. Reconnect before retrying.');
    });
    try { await _service.write(_target!.id, const [4]).timeout(const Duration(seconds: 3)); }
    catch (_) { if (_current(generation)) _syncError('Could not request contacts. Reconnect and retry.'); }
  }

  void _syncError(String message) {
    _syncFailed = true;
    _contactDeadline?.cancel(); _incoming = null; _contactCount = null;
    state = state.copyWith(syncing: false, contactMessage: message);
  }

  void _data(List<int> bytes) {
    final rx = RxObservation.parse(bytes, DateTime.now());
    if (rx != null) state = state.copyWith(lastRx: rx, contactMessage: state.contactMessage);
    if (!state.syncing) return;
    try {
      if (bytes.first == 1) { _syncError('Radio rejected contact sync. Reconnect and retry.'); return; }
      if (bytes.first == 2) {
        if (bytes.length != 5 || _contactCount != null) throw const FormatException();
        final count = ByteData.sublistView(Uint8List.fromList(bytes)).getUint32(1, Endian.little);
        if (count > 5000) throw const FormatException();
        _contactCount = count;
      } else if (bytes.first == 3) {
        if (_contactCount == null) throw const FormatException();
        final contact = MeshContact.parse(bytes);
        _incoming![contact.key] = contact;
        if (_incoming!.length > _contactCount!) throw const FormatException();
      } else if (bytes.first == 4) {
        if (bytes.length != 5 || _contactCount == null || _incoming!.length != _contactCount) throw const FormatException();
        final contacts = _incoming!.values.toList()..sort((a,b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _contactDeadline?.cancel(); _incoming = null; _contactCount = null;
        state = state.copyWith(contacts: List.unmodifiable(contacts), syncing: false, syncedAt: DateTime.now());
      }
    } on FormatException { _syncError('Incomplete or invalid contact data. Reconnect and retry.'); }
  }

  Future<void> _fail(int generation, Object error) async {
    if (!_current(generation)) return;
    final failure = error is RadioException ? error.failure : RadioFailure.transport;
    final retry = failure == RadioFailure.transport && _identifiedBefore &&
      _autoReconnect && _target != null && _attempt < 5;
    final cleanupGeneration = ++_generation;
    await _cleanup(keepSession: retry);
    if (!_current(cleanupGeneration)) return;
    if (retry) {
      _attempt++;
      state = state.copyWith(phase: RadioPhase.reconnecting, syncing: false,
        retryAttempt: _attempt, contactMessage: 'Radio disconnected; previously loaded contacts may be stale.');
      _retry = Timer(ref.read(reconnectDelayProvider)(_attempt), () {
        if (!_current(cleanupGeneration)) return;
        state = state.copyWith(phase: RadioPhase.connecting);
        try { _connectLink(cleanupGeneration, _target!.id); }
        catch (e) { unawaited(_fail(cleanupGeneration, e)); }
      });
    } else {
      state = RadioState(phase: RadioPhase.failed, failure: failure,
        autoReconnect: _autoReconnect, contacts: state.contacts, syncedAt: state.syncedAt,
        contactMessage: 'Radio disconnected; previously loaded contacts may be stale.');
    }
  }

  Future<void> setAutoReconnect(bool enabled) async {
    _autoReconnect = enabled;
    state = state.copyWith(autoReconnect: enabled, contactMessage: state.contactMessage);
    if (!enabled && state.phase == RadioPhase.reconnecting) await disconnect();
  }
  Future<void> background() async {
    if (_identifiedBefore && (state.phase == RadioPhase.ready || state.phase == RadioPhase.reconnecting || state.phase == RadioPhase.connecting || state.phase == RadioPhase.identifying)) return;
    if (state.phase == RadioPhase.scanning) await stopScan();
    else if (state.phase == RadioPhase.authorizing || state.phase == RadioPhase.connecting || state.phase == RadioPhase.identifying) await disconnect();
  }
  Future<void> disconnect() async {
    final generation = ++_generation; _retry?.cancel();
    _target = null; _identifiedBefore = false; _attempt = 0;
    final failure = await _cleanup();
    if (_current(generation)) state = _empty(failure: failure,
      phase: failure == null ? RadioPhase.idle : RadioPhase.failed);
  }
  Future<RadioFailure?> _cleanup({bool keepSession = false}) async {
    _deadline?.cancel(); _contactDeadline?.cancel(); _retry?.cancel();
    final scan = _scan; final link = _link; final notifications = _notifications;
    _scan = null; _link = null; _notifications = null;
    _expected = null; _response = null; _incoming = null; _contactCount = null;
    RadioFailure? failure;
    for (final subscription in <StreamSubscription<Object>?>[scan, notifications, link]) {
      try { await subscription?.cancel(); } catch (_) { failure = RadioFailure.transport; }
    }
    if (!keepSession) {
      try { await _service.endSession(); } catch (_) { failure = RadioFailure.transport; }
    }
    return failure;
  }
  Future<void> openSettings() async {
    try { await _service.openSettings(); } catch (e) { await _fail(_generation, e); }
  }
}
