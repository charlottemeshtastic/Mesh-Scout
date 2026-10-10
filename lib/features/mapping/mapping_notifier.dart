import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'mapping_service.dart';
import '../../common/mesh_data.dart';

final backgroundGpsProvider =
    NotifierProvider<BackgroundGps, bool>(BackgroundGps.new);

class BackgroundGps extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

final mappingServiceProvider =
    Provider<MappingService>((ref) => throw UnimplementedError());
final mappingProvider =
    NotifierProvider<MappingNotifier, MappingState>(MappingNotifier.new);

class MappingState {
  const MappingState(
      {this.loading = true,
      this.recording = false,
      this.busy = false,
      this.points = const [],
      this.sessions = const [],
      this.selected,
      this.observations = const [],
      this.message});
  final bool loading;
  final bool recording;
  final bool busy;
  final List<GpsPoint> points;
  final List<MappingSession> sessions;
  final MappingSession? selected;
  final List<CoverageObservation> observations;
  List<CoverageObservation> get displayedObservations =>
      recording || points.isNotEmpty
          ? observations
          : selected?.observations ?? const [];
  final String? message;
  List<GpsPoint> get displayedPoints =>
      recording || points.isNotEmpty ? points : selected?.points ?? const [];
}

class MappingNotifier extends Notifier<MappingState> {
  StreamSubscription<GpsPoint>? _positions;
  DateTime? _started;
  int _generation = 0;
  bool _disposed = false;
  bool _loadFailed = false;
  bool _starting = false;
  bool _keepBackground = false;
  MappingService get _service => ref.read(mappingServiceProvider);

  @override
  MappingState build() {
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      unawaited(_positions?.cancel());
    });
    return const MappingState();
  }

  Future<void> initialize() async {
    if (!state.loading) return;
    try {
      final sessions = decodeSessions(await _service.load());
      if (_disposed) return;
      _loadFailed = false;
      state =
          MappingState(loading: false, sessions: List.unmodifiable(sessions));
    } catch (_) {
      if (_disposed) return;
      _loadFailed = true;
      state = const MappingState(
          loading: false,
          message:
              'Saved sessions could not be loaded. Restart the app to retry.');
    }
  }

  Future<void> importSession(MappingSession session) async {
    if (state.loading ||
        state.busy ||
        state.recording ||
        state.points.isNotEmpty ||
        _loadFailed) return;
    if (state.sessions.length >= 1000)
      throw const FormatException('Session limit reached.');
    final sessions = [session, ...state.sessions];
    await _service.save(encodeSessions(sessions));
    if (ref.mounted)
      state = MappingState(
          loading: false,
          sessions: List.unmodifiable(sessions),
          selected: session);
  }

  Future<void> start({bool background = false}) async {
    if (state.loading ||
        state.busy ||
        state.recording ||
        state.points.isNotEmpty) {
      return;
    }
    if (_loadFailed) return;
    final generation = ++_generation;
    _started = null;
    _starting = true;
    state = MappingState(loading: false, busy: true, sessions: state.sessions);
    try {
      await _service.authorize();
      if (_disposed || generation != _generation) return;
      _started = DateTime.now();
      _keepBackground = background;
      final service = _service;
      if (service is BackgroundMappingService) {
        await (service as BackgroundMappingService)
            .configureRecording(background, _started!);
      } else if (background) {
        throw StateError('Background GPS is unavailable on this platform.');
      }
      if (_disposed || generation != _generation) return;
      _starting = false;
      state = MappingState(
          loading: false,
          recording: true,
          sessions: state.sessions,
          message: 'Waiting for a GPS fix…');
      _positions = _service.positions().listen((point) {
        if (_disposed || generation != _generation || !state.recording) return;
        if (!point.valid ||
            point.time
                .isBefore(_started!.subtract(const Duration(seconds: 5)))) {
          return;
        }
        if (state.points.isNotEmpty &&
            !point.time.isAfter(state.points.last.time)) {
          return;
        }
        if (state.points.length >= 10000) {
          unawaited(stop(reason: 'Route limit reached; session saved.'));
          return;
        }
        state = MappingState(
            loading: false,
            recording: true,
            sessions: state.sessions,
            observations: state.observations,
            points: List.unmodifiable([...state.points, point]));
      }, onError: (Object error) {
        unawaited(stop(reason: 'GPS stopped. ${error.toString()}'));
      }, onDone: () {
        if (!_disposed && generation == _generation && state.recording) {
          unawaited(stop(reason: 'GPS stream ended; recording stopped.'));
        }
      });
    } catch (error) {
      _starting = false;
      if (_disposed || generation != _generation) return;
      state = MappingState(
          loading: false, sessions: state.sessions, message: error.toString());
    }
  }

  Future<void> stop({String? reason}) async {
    if (state.busy) return;
    if (!state.recording && state.points.isEmpty) return;
    ++_generation;
    final points = state.points;
    final observations = state.observations;
    final sessions = state.sessions;
    state = MappingState(
        loading: false,
        busy: true,
        points: points,
        observations: observations,
        sessions: sessions);
    try {
      final subscription = _positions;
      _positions = null;
      await subscription?.cancel();
      if (points.isEmpty) {
        if (!_disposed) {
          state = MappingState(
              loading: false,
              sessions: sessions,
              message: reason ?? 'No GPS fixes received; no session saved.');
        }
        return;
      }
      final started = _started!;
      final session = MappingSession(
          id: started.microsecondsSinceEpoch.toString(),
          started: started,
          ended: DateTime.now(),
          points: points,
          observations: observations);
      final updated = [session, ...sessions];
      await _service.save(encodeSessions(updated));
      if (_disposed) return;
      state = MappingState(
          loading: false,
          sessions: List.unmodifiable(updated),
          selected: session,
          message: reason ?? 'Session saved on this phone.');
    } catch (_) {
      if (_disposed) return;
      state = MappingState(
          loading: false,
          sessions: sessions,
          points: points,
          observations: observations,
          message:
              'Could not save this route. Tap Retry save before starting another.');
    }
  }

  void capture(RxObservation rx) {
    if (!state.recording ||
        state.points.isEmpty ||
        state.observations.length >= 10000) {
      return;
    }
    final point = state.points.last;
    final age = rx.time.difference(point.time);
    if (age.isNegative || age > const Duration(seconds: 15)) return;
    final observation = CoverageObservation(
        point: point, rssi: rx.rssi, snr: rx.snr, time: rx.time);
    state = MappingState(
        loading: false,
        recording: true,
        points: state.points,
        sessions: state.sessions,
        observations: List.unmodifiable([...state.observations, observation]));
  }

  Future<void> background() async {
    // Foreground routes stop on app switching; opted-in routes keep recording.
    if (_starting) {
      _starting = false;
      ++_generation;
      state = MappingState(
          loading: false,
          sessions: state.sessions,
          message: 'Recording start cancelled when leaving the app.');
    } else if (state.recording && !_keepBackground) {
      await stop(
          reason:
              'Saved when leaving the app. Tap Start Mapping to record again.');
    }
  }

  void select(MappingSession session) {
    if (state.recording || state.busy || state.points.isNotEmpty) return;
    state = MappingState(
        loading: false, sessions: state.sessions, selected: session);
  }

  Future<void> rename(MappingSession session, String input) async {
    if (state.recording ||
        state.busy ||
        _loadFailed ||
        state.points.isNotEmpty) {
      return;
    }
    final value = input.trim();
    if (value.length > 80 || value.contains(RegExp(r'[\x00-\x1f]'))) {
      state = MappingState(
          loading: false,
          sessions: state.sessions,
          selected: state.selected,
          message:
              'Use a name of up to 80 characters without control characters.');
      return;
    }
    if (!state.sessions.any((s) => s.id == session.id)) return;
    final previous = state;
    final updated = previous.sessions
        .map((s) =>
            s.id == session.id ? s.renamed(value.isEmpty ? null : value) : s)
        .toList();
    state = MappingState(
        loading: false,
        busy: true,
        sessions: previous.sessions,
        selected: previous.selected);
    try {
      await _service.save(encodeSessions(updated));
      if (_disposed) return;
      state = MappingState(
          loading: false,
          sessions: List.unmodifiable(updated),
          selected: previous.selected?.id == session.id
              ? updated.firstWhere((s) => s.id == session.id)
              : previous.selected,
          message: 'Session name saved.');
    } catch (_) {
      if (_disposed) return;
      state = MappingState(
          loading: false,
          sessions: previous.sessions,
          selected: previous.selected,
          message: 'Could not rename the session. Try again.');
    }
  }

  Future<void> delete(MappingSession session) async {
    if (state.recording ||
        state.busy ||
        _loadFailed ||
        state.points.isNotEmpty) {
      return;
    }
    final previous = state;
    state = MappingState(
        loading: false,
        busy: true,
        sessions: previous.sessions,
        selected: previous.selected);
    try {
      final updated =
          previous.sessions.where((s) => s.id != session.id).toList();
      await _service.save(encodeSessions(updated));
      if (_disposed) return;
      state = MappingState(
          loading: false,
          sessions: List.unmodifiable(updated),
          selected:
              previous.selected?.id == session.id ? null : previous.selected);
    } catch (_) {
      if (!_disposed) {
        state = MappingState(
            loading: false,
            sessions: previous.sessions,
            selected: previous.selected,
            message: 'Could not delete the session. Try again.');
      }
    }
  }
}
