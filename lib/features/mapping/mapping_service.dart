import 'dart:convert';

class GpsPoint {
  const GpsPoint(
    this.latitude,
    this.longitude,
    this.accuracy,
    this.time, {
    this.altitude,
    this.speed,
  });
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime time;

  /// Altitude in metres above the WGS84 ellipsoid, when the fix reports one.
  final double? altitude;

  /// Ground speed in metres per second, when the fix reports one.
  final double? speed;

  bool get valid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      accuracy.isFinite &&
      accuracy >= 0 &&
      accuracy <= 100;

  Map<String, Object> toJson() => {
        'lat': latitude,
        'lon': longitude,
        'accuracy': accuracy,
        'time': time.toUtc().toIso8601String(),
        if (altitude != null && altitude!.isFinite) 'altitude': altitude!,
        if (speed != null && speed!.isFinite) 'speed': speed!,
      };
  factory GpsPoint.fromJson(Map<String, dynamic> json) => GpsPoint(
        (json['lat'] as num).toDouble(),
        (json['lon'] as num).toDouble(),
        (json['accuracy'] as num).toDouble(),
        DateTime.parse(json['time'] as String),
        altitude: (json['altitude'] as num?)?.toDouble(),
        speed: (json['speed'] as num?)?.toDouble(),
      );
}

class CoverageObservation {
  const CoverageObservation({
    required this.point,
    required this.rssi,
    required this.snr,
    required this.time,
  });
  final GpsPoint point;
  final int rssi;
  final double snr;
  final DateTime time;
  Map<String, Object> toJson() => {
        'point': point.toJson(),
        'rssi': rssi,
        'snr': snr,
        'time': time.toUtc().toIso8601String(),
      };
  factory CoverageObservation.fromJson(Map<String, dynamic> json) =>
      CoverageObservation(
        point: GpsPoint.fromJson(json['point'] as Map<String, dynamic>),
        rssi: json['rssi'] as int,
        snr: (json['snr'] as num).toDouble(),
        time: DateTime.parse(json['time'] as String),
      );
}

class MappingSession {
  const MappingSession({
    required this.id,
    required this.started,
    required this.ended,
    required this.points,
    this.observations = const [],
    this.name,
    this.planned = false,
    this.preset,
  });
  final bool planned;
  final String id;
  final String? name;

  /// Radio modem settings (RadioPreset.key) in use while this route recorded.
  final String? preset;
  MappingSession renamed(String? name) => MappingSession(
        id: id,
        planned: planned,
        preset: preset,
        started: started,
        ended: ended,
        points: points,
        observations: observations,
        name: name,
      );
  final DateTime started;
  final DateTime ended;
  final List<GpsPoint> points;
  final List<CoverageObservation> observations;
  Map<String, Object> toJson() => {
        'id': id,
        if (planned) 'planned': true,
        if (name != null) 'name': name!,
        if (preset != null) 'preset': preset!,
        'started': started.toUtc().toIso8601String(),
        'ended': ended.toUtc().toIso8601String(),
        'points': points.map((p) => p.toJson()).toList(),
        'observations': observations.map((p) => p.toJson()).toList(),
      };
  factory MappingSession.fromJson(Map<String, dynamic> json) => MappingSession(
        id: json['id'] as String,
        planned: json['planned'] == true,
        name: json['name'] as String?,
        preset: json['preset'] is String ? json['preset'] as String : null,
        started: DateTime.parse(json['started'] as String),
        ended: DateTime.parse(json['ended'] as String),
        observations: List.unmodifiable(
          (json['observations'] as List<dynamic>? ?? []).map(
            (p) => CoverageObservation.fromJson(p as Map<String, dynamic>),
          ),
        ),
        points: List.unmodifiable(
          (json['points'] as List<dynamic>).map(
            (p) => GpsPoint.fromJson(p as Map<String, dynamic>),
          ),
        ),
      );
}

abstract interface class MappingService {
  Future<void> authorize();
  Stream<GpsPoint> positions();
  Future<String?> load();
  Future<void> save(String json);
}

List<MappingSession> decodeSessions(String? data) => data == null
    ? []
    : (jsonDecode(data) as List<dynamic>)
        .map((s) => MappingSession.fromJson(s as Map<String, dynamic>))
        .toList();
String encodeSessions(List<MappingSession> sessions) =>
    jsonEncode(sessions.map((s) => s.toJson()).toList());

abstract interface class BackgroundMappingService {
  Future<void> configureRecording(bool background, DateTime started);
}

abstract interface class CheckpointMappingService {
  Future<void> checkpoint(MappingSession session);
}
