import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'mapping_service.dart';

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
      this.message});
  final bool loading;
  final bool recording;
  final bool busy;
  final List<GpsPoint> points;
  final List<MappingSession> sessions;
  final MappingSession? selected;
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

  Future<void> start() async {
    if (state.loading ||
        state.busy ||
        state.recording ||
        state.points.isNotEmpty) {
      return;
    }
    if (_loadFailed) return;
    final generation = ++_generation;
    _started = null;
    state = MappingState(loading: false, busy: true, sessions: state.sessions);
    try {
      await _service.authorize();
      if (_disposed || generation != _generation) return;
      _started = DateTime.now();
      state = MappingState(
          loading: false,
          recording: true,
          sessions: state.sessions,
          message: 'Waiting for a GPS fix…');
      _positions = _service.positions().listen((point) {
        if (_disposed || generation != _generation || !state.recording) return;
        if (!point.valid ||
            point.time.isBefore(_started!.subtract(const Duration(seconds: 5)))) {
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
            points: List.unmodifiable([...state.points, point]));
      }, onError: (Object error) {
        unawaited(stop(reason: 'GPS stopped. ${error.toString()}'));
      }, onDone: () {
        if (!_disposed && generation == _generation && state.recording) {
          unawaited(stop(reason: 'GPS stream ended; recording stopped.'));
        }
      });
    } catch (error) {
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
    final sessions = state.sessions;
    state = MappingState(
        loading: false, busy: true, points: points, sessions: sessions);
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
          points: points);
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
          message:
              'Could not save this route. Tap Retry save before starting another.');
    }
  }

  Future<void> background() async {
    // GPS recording is foreground-only; cancel a pending permission start too.
    if (state.busy && !state.recording && _started == null) {
      ++_generation;
      state = MappingState(
          loading: false,
          sessions: state.sessions,
          message: 'Recording start cancelled when leaving the app.');
    } else if (state.recording) {
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

  Future<void> delete(MappingSession session) async {
    if (state.recording || state.busy || _loadFailed || state.points.isNotEmpty) {
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
