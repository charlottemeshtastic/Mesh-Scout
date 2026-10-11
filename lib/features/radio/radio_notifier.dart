import 'package:clock/clock.dart';
import 'radio_observation.dart';
import 'dart:async';
import 'dart:convert';

import 'inbox_journal.dart';

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../common/mesh_data.dart';
import 'ble_service.dart';

final clockProvider = Provider<Clock>((ref) => const Clock());
const maxRadioObservations = 200;

final bleServiceProvider = Provider<BleService>(
  (ref) => throw UnimplementedError(),
);
final reconnectDelayProvider = Provider<Duration Function(int)>(
  (ref) => (attempt) => Duration(seconds: [3, 6, 12, 24, 30][attempt - 1]),
);
final reconnectTimerProvider =
    Provider<Timer Function(Duration, void Function())>((ref) => Timer.new);
final radioTimerProvider = Provider<Timer Function(Duration, void Function())>(
  (ref) => Timer.new,
);
final radioProvider = NotifierProvider<RadioNotifier, RadioState>(
  RadioNotifier.new,
);

class RadioChannel {
  const RadioChannel(this.index, this.name);
  final int index;
  final String name;
}

enum RadioPhase {
  idle,
  authorizing,
  scanning,
  connecting,
  identifying,
  ready,
  reconnecting,
  failed,
}

class RadioState {
  const RadioState({
    this.phase = RadioPhase.idle,
    this.devices = const [],
    this.failure,
    this.contacts = const [],
    this.syncing = false,
    this.contactMessage,
    this.syncedAt,
    this.lastRx,
    this.autoReconnect = true,
    this.retryAttempt = 0,
    this.messagingBusy = false,
    this.messageEvent,
    this.channels = const [],
    this.channelsLoading = false,
    this.controlsBusy = false,
    this.heard = const [],
    this.remoteEvent,
    this.preset,
    this.collecting = false,
    this.observations = const [],
    this.receivedCount = 0,
    this.malformedCount = 0,
  });
  final bool collecting;
  final List<RadioObservation> observations;
  final int receivedCount;
  final int malformedCount;
  final List<MeshContact> heard;

  /// Modem settings reported while identifying the connected radio.
  final RadioPreset? preset;
  final List<int>? remoteEvent;
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
  final bool messagingBusy;
  final List<RadioChannel> channels;
  final bool channelsLoading;
  final bool controlsBusy;
  final List<int>? messageEvent;
  bool get busy => phase != RadioPhase.idle && phase != RadioPhase.failed;
  RadioState copyWith({
    List<MeshContact>? heard,
    List<int>? remoteEvent,
    RadioPhase? phase,
    List<RadioDevice>? devices,
    List<MeshContact>? contacts,
    bool? syncing,
    String? contactMessage,
    DateTime? syncedAt,
    RxObservation? lastRx,
    bool? autoReconnect,
    int? retryAttempt,
    bool? messagingBusy,
    List<int>? messageEvent,
    List<RadioChannel>? channels,
    bool? channelsLoading,
    bool? controlsBusy,
    RadioPreset? preset,
    bool? collecting,
    List<RadioObservation>? observations,
    int? receivedCount,
    int? malformedCount,
  }) =>
      RadioState(
        collecting: collecting ?? this.collecting,
        observations: observations ?? this.observations,
        receivedCount: receivedCount ?? this.receivedCount,
        malformedCount: malformedCount ?? this.malformedCount,
        preset: preset ?? this.preset,
        heard: heard ?? this.heard,
        remoteEvent: remoteEvent ?? this.remoteEvent,
        phase: phase ?? this.phase,
        devices: devices ?? this.devices,
        failure: failure,
        contacts: contacts ?? this.contacts,
        syncing: syncing ?? this.syncing,
        contactMessage: contactMessage,
        syncedAt: syncedAt ?? this.syncedAt,
        lastRx: lastRx ?? this.lastRx,
        autoReconnect: autoReconnect ?? this.autoReconnect,
        retryAttempt: retryAttempt ?? this.retryAttempt,
        messagingBusy: messagingBusy ?? this.messagingBusy,
        messageEvent: messageEvent ?? this.messageEvent,
        channels: channels ?? this.channels,
        channelsLoading: channelsLoading ?? this.channelsLoading,
        controlsBusy: controlsBusy ?? this.controlsBusy,
      );
}

class RadioNotifier extends Notifier<RadioState> {
  StreamSubscription<RadioDevice>? _scan;
  StreamSubscription<RadioLink>? _link;
  StreamSubscription<List<int>>? _notifications;
  Timer? _deadline;
  Timer? _retry;
  Timer? _contactDeadline;
  Completer<List<int>>? _response;
  Completer<List<int>>? _messageReply;
  Set<int> _messageTypes = {};
  String? get companionId => _target?.id;
  int get mtu => _mtu;
  int get channelCapacity => _channelCapacity;
  int get sessionToken => _generation;
  int? _expected;
  int _generation = 0;
  bool _disposed = false;
  final _cancelOperations = <void Function()>{};
  bool _autoReconnect = true;
  bool _identifiedBefore = false;
  int _attempt = 0;
  int _mtu = 0;
  int _channelCapacity = 0;
  RadioDevice? _target;
  RadioDevice? preferred;
  bool resumeMonitoring = false;
  void restorePreferred(
    RadioDevice device,
    List<MeshContact> contacts,
    DateTime? synced,
  ) {
    preferred = device;
    state = state.copyWith(
      contacts: List.unmodifiable(contacts),
      syncedAt: synced,
      contactMessage: 'Saved contacts for ${device.name}; refresh to verify.',
    );
  }

  Future<void> connectPreferred() async {
    final device = preferred;
    if (device == null || state.busy) return;
    state = state.copyWith(phase: RadioPhase.idle, devices: [device]);
    await connect(device);
  }

  Map<String, MeshContact>? _incoming;
  int? _contactCount;
  bool _syncFailed = false;
  BleService? _cachedService;
  BleService get _service {
    final existing = _cachedService;
    if (existing != null) return existing;
    final BleService created = ref.read(bleServiceProvider);
    _cachedService = created;
    return created;
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  RadioState _empty({
    RadioPhase phase = RadioPhase.idle,
    RadioFailure? failure,
  }) =>
      RadioState(
        phase: phase,
        failure: failure,
        autoReconnect: _autoReconnect,
        contacts: state.contacts,
        syncedAt: state.syncedAt,
        observations: state.observations,
        receivedCount: state.receivedCount,
        malformedCount: state.malformedCount,
      );

  @override
  RadioState build() {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _retry?.cancel();
      unawaited(_cleanup());
    });
    return const RadioState();
  }

  Future<void> scan() async {
    if (state.busy) return;
    final generation = ++_generation;
    state = _empty(phase: RadioPhase.authorizing).copyWith(
      observations: const [],
      receivedCount: 0,
      malformedCount: 0,
    );
    try {
      await _service.authorize();
      if (!_current(generation)) return;
      state = _empty(phase: RadioPhase.scanning);
      _scan = _service.scan().listen((device) {
        if (!_current(generation)) return;
        final devices = {
          for (final d in state.devices) d.id: d,
          device.id: device,
        };
        state = state.copyWith(devices: List.unmodifiable(devices.values));
      }, onError: (Object e) => unawaited(_fail(generation, e)));
      _deadline = ref.read(radioTimerProvider)(
        const Duration(seconds: 10),
        () => unawaited(stopScan()),
      );
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
      state = state.copyWith(phase: RadioPhase.idle);
    } catch (e) {
      await _fail(generation, e);
    }
  }

  Future<void> connect(RadioDevice device) async {
    if ((state.phase != RadioPhase.idle &&
            state.phase != RadioPhase.scanning) ||
        !state.devices.any((d) => d.id == device.id)) {
      return;
    }
    if (preferred?.id != device.id) {
      state = RadioState(devices: state.devices, autoReconnect: _autoReconnect);
    }
    _target = device;
    _identifiedBefore = false;
    _attempt = 0;
    final generation = ++_generation;
    state = _empty(phase: RadioPhase.connecting);
    _deadline?.cancel();
    final scan = _scan;
    _scan = null;
    try {
      await scan?.cancel();
      if (!_current(generation)) return;
      await _service.authorize();
      if (!_current(generation)) return;
      _connectLink(generation, device.id);
    } catch (e) {
      await _fail(generation, e);
    }
  }

  void _connectLink(int generation, String id) {
    _deadline = ref.read(radioTimerProvider)(
      const Duration(seconds: 20),
      () => unawaited(
        _fail(generation, const RadioException(RadioFailure.transport)),
      ),
    );
    _link = _service.connect(id).listen(
      (link) {
        if (!_current(generation)) return;
        if (link == RadioLink.connected &&
            state.phase == RadioPhase.connecting) {
          state = state.copyWith(phase: RadioPhase.identifying);
          unawaited(_identify(generation, id));
        } else if (link == RadioLink.disconnected) {
          unawaited(
            _fail(generation, const RadioException(RadioFailure.transport)),
          );
        }
      },
      onError: (Object e) => unawaited(_fail(generation, e)),
      onDone: () => unawaited(
        _fail(generation, const RadioException(RadioFailure.transport)),
      ),
    );
  }

  Future<void> _identify(int generation, String id) async {
    try {
      await _withTimeout(_service.discover(id), const Duration(seconds: 5));
      if (!_current(generation)) return;
      _mtu = await _withTimeout(
        _service.negotiateMtu(id),
        const Duration(seconds: 5),
      );
      if (!_current(generation)) return;
      if (_mtu < minimumIdentificationMtu) {
        throw const RadioException(RadioFailure.protocol);
      }
      _notifications = _service.notifications(id).listen((bytes) {
        if (!_current(generation) || bytes.isEmpty) return;
        if (state.phase == RadioPhase.ready) _data(bytes);
        final minimum = _expected == 5 ? 58 : 80;
        if (bytes.first == _expected && bytes.length >= minimum) {
          final response = _response;
          if (response != null && !response.isCompleted) {
            response.complete(bytes);
          }
        }
      }, onError: (Object e) => unawaited(_fail(generation, e)));
      final self = await _exchange(generation, id, appStart, 5);
      if (!_current(generation)) return;
      final preset = RadioPreset.fromSelfInfo(self);
      final info = await _exchange(generation, id, deviceQuery, 13);
      if (!_current(generation)) return;
      if (info[1] < 3) throw const RadioException(RadioFailure.protocol);
      _channelCapacity = info[3] <= 64 ? info[3] : 0;
      _deadline?.cancel();
      _expected = null;
      _response = null;
      _identifiedBefore = true;
      preferred = _target;
      resumeMonitoring = true;
      _attempt = 0;
      _syncFailed = false;
      state = state.copyWith(
        phase: RadioPhase.ready,
        retryAttempt: 0,
        preset: preset,
      );
    } catch (e) {
      await _fail(generation, e);
    }
  }

  Future<List<int>> _exchange(
    int generation,
    String id,
    List<int> command,
    int expected,
  ) async {
    _expected = expected;
    final response = Completer<List<int>>();
    _response = response;
    for (var attempt = 0; attempt < 2; attempt++) {
      if (!_current(generation)) {
        throw const RadioException(RadioFailure.transport);
      }
      await _withTimeout(
        _service.write(id, command),
        const Duration(seconds: 3),
      );
      try {
        return await _withTimeout(response.future, const Duration(seconds: 2));
      } on TimeoutException {
        if (attempt == 1) throw const RadioException(RadioFailure.protocol);
      }
    }
    throw const RadioException(RadioFailure.protocol);
  }

  Future<void> refreshContacts() async {
    if (state.phase != RadioPhase.ready ||
        state.syncing ||
        state.messagingBusy ||
        state.channelsLoading ||
        state.controlsBusy ||
        _target == null) {
      return;
    }
    if (_syncFailed) {
      state = state.copyWith(
        contactMessage: 'Reconnect before starting another contact sync.',
      );
      return;
    }
    if (_mtu < 151) {
      state = state.copyWith(
        contactMessage:
            'Radio Bluetooth MTU is too small for contacts. Reconnect and retry.',
      );
      return;
    }
    final generation = _generation;
    _incoming = {};
    _contactCount = null;
    state = state.copyWith(syncing: true);
    _contactDeadline = ref.read(radioTimerProvider)(
      const Duration(seconds: 30),
      () {
        if (_current(generation) && state.syncing) {
          _syncError('Contact sync timed out. Reconnect before retrying.');
        }
      },
    );
    try {
      await _withTimeout(
        _service.write(_target!.id, const [4]),
        const Duration(seconds: 3),
      );
    } catch (_) {
      if (_current(generation)) {
        _syncError('Could not request contacts. Reconnect and retry.');
      }
    }
  }

  void _syncError(String message) {
    _syncFailed = true;
    _contactDeadline?.cancel();
    _incoming = null;
    _contactCount = null;
    state = state.copyWith(syncing: false, contactMessage: message);
  }

  Future<void> refreshChannels() async {
    if (state.phase != RadioPhase.ready ||
        state.syncing ||
        state.messagingBusy ||
        state.channelsLoading ||
        state.controlsBusy) {
      return;
    }
    final generation = _generation;
    state = state.copyWith(channelsLoading: true);
    final channels = <RadioChannel>[];
    try {
      if (_channelCapacity == 0) {
        throw StateError('Radio reports no supported channel slots.');
      }
      for (var index = 0; index < _channelCapacity; index++) {
        if (!_current(generation)) {
          return;
        }
        final reply = await messageCommand(
          [31, index],
          {18},
          allowNotFound: true,
        );
        if (reply.first == 1) {
          continue;
        }
        if (reply.length != 34 || reply[1] != index) {
          _syncFailed = true;
          throw const FormatException(
            'Invalid channel index. Reconnect before retrying.',
          );
        }
        final name = utf8.decode(
          reply.sublist(2, 34).takeWhile((b) => b != 0).toList(),
        );
        // Empty names indicate unused slots; expose configured names only.
        if (name.isNotEmpty) {
          channels.add(RadioChannel(index, name));
        }
      }
      if (_current(generation)) {
        state = state.copyWith(
          channels: List.unmodifiable(channels),
          contactMessage: channels.isEmpty
              ? 'No named channels configured on the radio.'
              : 'Channels loaded.',
        );
      }
    } catch (_) {
      if (_current(generation)) {
        _syncFailed = true;
        state = state.copyWith(
          contactMessage: 'Could not load channels. Reconnect and retry.',
        );
      }
    } finally {
      if (_current(generation)) {
        state = state.copyWith(
          channelsLoading: false,
          contactMessage: state.contactMessage,
        );
      }
    }
  }

  bool beginControls() {
    if (state.phase != RadioPhase.ready ||
        state.syncing ||
        state.messagingBusy ||
        state.channelsLoading ||
        state.controlsBusy ||
        _syncFailed) {
      return false;
    }
    state = state.copyWith(controlsBusy: true);
    return true;
  }

  void endControls(int token) {
    if (_current(token)) {
      state = state.copyWith(controlsBusy: false);
    }
  }

  Future<List<int>> messageCommand(
    List<int> command,
    Set<int> replies, {
    bool allowNotFound = false,
    bool control = false,
  }) async {
    if (state.phase != RadioPhase.ready ||
        state.syncing ||
        state.messagingBusy ||
        (state.channelsLoading && command.first != 31) ||
        (state.controlsBusy && !control) ||
        _target == null ||
        _syncFailed) {
      throw StateError(
        'Connect or reconnect the radio and finish contact sync first.',
      );
    }
    final generation = _generation;
    final reply = Completer<List<int>>();
    _messageReply = reply;
    _messageTypes = {...replies, 1};
    state = state.copyWith(messagingBusy: true);
    // Install the deadline before writing: replies can arrive during the write.
    final response = _withTimeout(reply.future, const Duration(seconds: 8));
    unawaited(response.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _withTimeout(
        _service.write(_target!.id, command),
        const Duration(seconds: 3),
      );
      final bytes = await response;
      if (bytes.first == 1 &&
          allowNotFound &&
          command.first == 31 &&
          bytes.length == 2 &&
          bytes[1] == 2) {
        return bytes;
      }
      if (bytes.first == 1) {
        throw StateError('Radio rejected the request.');
      }
      if (bytes.first == 0 && bytes.length != 1) {
        throw const FormatException('Invalid acceptance.');
      }
      if (bytes.first == 6 && bytes.length != 10) {
        throw const FormatException('Invalid radio acceptance.');
      }
      return bytes;
    } catch (_) {
      // Never retry a transmission or let a late reply match another command.
      if (_current(generation)) {
        _syncFailed = true;
      }
      rethrow;
    } finally {
      // Consume cancellation errors even when the write failed first.
      unawaited(response.then<void>((_) {}, onError: (Object _) {}));
      if (_current(generation)) {
        _messageReply = null;
        _messageTypes = {};
        state = state.copyWith(messagingBusy: false);
      }
    }
  }

  /// Collection is opt-in, live and foreground-only; no radio writes occur.
  void startCollection() {
    if (state.phase == RadioPhase.ready) {
      state = state.copyWith(collecting: true);
    }
  }

  void stopCollection() {
    state = state.copyWith(collecting: false);
  }

  void clearObservations() {
    state = state
        .copyWith(observations: const [], receivedCount: 0, malformedCount: 0);
  }

  void _collect(List<int> bytes) {
    // Advert/contact notifications alone have no RF measurements. Do not
    // fabricate metrics or pair them with an unrelated raw reception event.
    if (bytes.first != 0x88) return;
    final observation =
        parseRadioObservation(bytes, ref.read(clockProvider).now());
    if (observation == null) {
      state = state.copyWith(malformedCount: state.malformedCount + 1);
      return;
    }
    final recent = [observation, ...state.observations];
    state = state.copyWith(
        observations: List.unmodifiable(recent.take(maxRadioObservations)),
        receivedCount: state.receivedCount + 1);
  }

  void _data(List<int> bytes) {
    if (bytes.isEmpty) return;
    if (state.collecting) _collect(bytes);
    if (bytes.first == 0x8a) {
      try {
        final contact = MeshContact.parse(bytes);
        state = state.copyWith(
          heard: List.unmodifiable([
            contact,
            ...state.heard.where((c) => c.key != contact.key).take(99),
          ]),
        );
      } on FormatException {
        /* Ignore malformed discovery frames. */
      }
    }
    if ([0x85, 0x86, 0x87, 0x8b, 0x8d].contains(bytes.first)) {
      state = state.copyWith(remoteEvent: List<int>.unmodifiable(bytes));
    }

    if (bytes.first == 0x82 || bytes.first == 0x83) {
      state = state.copyWith(messageEvent: List<int>.unmodifiable(bytes));
    }
    final reply = _messageReply;
    if (reply != null &&
        !reply.isCompleted &&
        _messageTypes.contains(bytes.first)) {
      if (bytes.first == 18) {
        // GET_CHANNEL includes a secret after byte 33. Never publish that key.
        if (bytes.length != 50) {
          reply.completeError(
            const FormatException('Invalid channel response.'),
          );
        } else {
          reply.complete(List<int>.unmodifiable(bytes.take(34)));
        }
      } else if (bytes.first == 13) {
        // DEVICE_INFO includes the Bluetooth PIN; never pass it to controls.
        final safe = [...bytes];
        for (var i = 4; i < safe.length && i < 8; i++) {
          safe[i] = 0;
        }
        reply.complete(List<int>.unmodifiable(safe));
      } else {
        if ([7, 8, 16, 17, 27].contains(bytes.first)) {
          _messageTypes = {};
          final generation = _generation;
          unawaited(
            ref.read(inboxJournalProvider).write(bytes, _target!.id).then(
              (_) {
                if (_current(generation) && !reply.isCompleted) {
                  reply.complete(List<int>.unmodifiable(bytes));
                }
              },
              onError: (Object error, StackTrace stack) {
                if (!reply.isCompleted) reply.completeError(error, stack);
              },
            ),
          );
        } else {
          reply.complete(List<int>.unmodifiable(bytes));
        }
      }
    }
    final rx = RxObservation.parse(bytes, DateTime.now());
    if (rx != null) {
      state = state.copyWith(lastRx: rx, contactMessage: state.contactMessage);
    }
    if (!state.syncing) return;
    try {
      if (bytes.first == 1) {
        _syncError('Radio rejected contact sync. Reconnect and retry.');
        return;
      }
      if (bytes.first == 2) {
        if (bytes.length != 5 || _contactCount != null) {
          throw const FormatException();
        }
        final count = ByteData.sublistView(Uint8List.fromList(bytes))
            .getUint32(1, Endian.little);
        if (count > 5000) throw const FormatException();
        _contactCount = count;
      } else if (bytes.first == 3) {
        if (_contactCount == null) throw const FormatException();
        final contact = MeshContact.parse(bytes);
        _incoming![contact.key] = contact;
        if (_incoming!.length > _contactCount!) throw const FormatException();
      } else if (bytes.first == 4) {
        if (bytes.length != 5 ||
            _contactCount == null ||
            _incoming!.length != _contactCount) {
          throw const FormatException();
        }
        final contacts = _incoming!.values.toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
        _contactDeadline?.cancel();
        _incoming = null;
        _contactCount = null;
        state = state.copyWith(
          contacts: List.unmodifiable(contacts),
          syncing: false,
          syncedAt: DateTime.now(),
        );
      }
    } on FormatException {
      _syncError('Incomplete or invalid contact data. Reconnect and retry.');
    }
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

    operation.then(
      (value) {
        finish();
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        finish();
        if (!result.isCompleted) {
          result.completeError(error, stack);
        }
      },
    );
    return result.future;
  }

  Future<void> _fail(int generation, Object error) async {
    if (!_current(generation)) return;
    stopCollection();
    final failure =
        error is RadioException ? error.failure : RadioFailure.transport;
    final retry = failure == RadioFailure.transport &&
        _identifiedBefore &&
        _autoReconnect &&
        _target != null &&
        _attempt < 5;
    final cleanupGeneration = ++_generation;
    await _cleanup(keepSession: retry);
    if (!_current(cleanupGeneration)) return;
    if (retry) {
      _attempt++;
      state = state.copyWith(
        phase: RadioPhase.reconnecting,
        controlsBusy: false,
        syncing: false,
        messagingBusy: false,
        channels: const [],
        channelsLoading: false,
        retryAttempt: _attempt,
        contactMessage:
            'Radio disconnected; previously loaded contacts may be stale.',
      );
      _retry = ref.read(reconnectTimerProvider)(
        ref.read(reconnectDelayProvider)(_attempt),
        () {
          if (!_current(cleanupGeneration)) return;
          state = state.copyWith(phase: RadioPhase.connecting);
          try {
            _connectLink(cleanupGeneration, _target!.id);
          } catch (e) {
            unawaited(_fail(cleanupGeneration, e));
          }
        },
      );
    } else {
      state = RadioState(
        phase: RadioPhase.failed,
        failure: failure,
        autoReconnect: _autoReconnect,
        observations: state.observations,
        receivedCount: state.receivedCount,
        malformedCount: state.malformedCount,
        contacts: state.contacts,
        syncedAt: state.syncedAt,
        contactMessage:
            'Radio disconnected; previously loaded contacts may be stale.',
      );
    }
  }

  /// Records modem settings read after the radio was identified.
  void updatePreset(RadioPreset? preset) {
    if (preset == null || state.phase != RadioPhase.ready) return;
    state = state.copyWith(
      preset: preset,
      contactMessage: state.contactMessage,
    );
  }

  Future<void> setAutoReconnect(bool enabled) async {
    _autoReconnect = enabled;
    state = state.copyWith(
      autoReconnect: enabled,
      contactMessage: state.contactMessage,
    );
    if (!enabled && state.phase == RadioPhase.reconnecting) await disconnect();
  }

  Future<void> background() async {
    stopCollection();
    if (_identifiedBefore &&
        (state.phase == RadioPhase.ready ||
            state.phase == RadioPhase.reconnecting ||
            state.phase == RadioPhase.connecting ||
            state.phase == RadioPhase.identifying)) {
      return;
    }
    if (state.phase == RadioPhase.scanning) {
      await stopScan();
    } else if (state.phase == RadioPhase.authorizing ||
        state.phase == RadioPhase.connecting ||
        state.phase == RadioPhase.identifying) {
      await disconnect();
    }
  }

  Future<void> disconnect() async {
    stopCollection();
    resumeMonitoring = false;
    final generation = ++_generation;
    _retry?.cancel();
    _target = null;
    _identifiedBefore = false;
    _attempt = 0;
    final failure = await _cleanup();
    if (_current(generation)) {
      state = _empty(
        failure: failure,
        phase: failure == null ? RadioPhase.idle : RadioPhase.failed,
      );
    }
  }

  Future<RadioFailure?> _cleanup({bool keepSession = false}) async {
    _deadline?.cancel();
    final cancellations = _cancelOperations.toList();
    _cancelOperations.clear();
    for (final cancel in cancellations) {
      cancel();
    }
    _contactDeadline?.cancel();
    _retry?.cancel();
    final scan = _scan;
    final link = _link;
    final notifications = _notifications;
    _scan = null;
    _link = null;
    _notifications = null;
    _expected = null;
    _response = null;
    _messageReply = null;
    _messageTypes = {};
    _incoming = null;
    _contactCount = null;
    RadioFailure? failure;
    for (final subscription in <StreamSubscription<Object>?>[
      scan,
      notifications,
      link,
    ]) {
      try {
        await subscription?.cancel();
      } catch (_) {
        failure = RadioFailure.transport;
      }
    }
    if (!keepSession) {
      try {
        await _service.endSession();
      } catch (_) {
        failure = RadioFailure.transport;
      }
    }
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
