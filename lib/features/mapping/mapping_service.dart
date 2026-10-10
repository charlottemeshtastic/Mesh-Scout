import 'dart:convert';

class GpsPoint {
  const GpsPoint(this.latitude, this.longitude, this.accuracy, this.time);
  final double latitude;
  final double longitude;
  final double accuracy;
  final DateTime time;

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
      };
  factory GpsPoint.fromJson(Map<String, dynamic> json) => GpsPoint(
        (json['lat'] as num).toDouble(),
        (json['lon'] as num).toDouble(),
        (json['accuracy'] as num).toDouble(),
        DateTime.parse(json['time'] as String),
      );
}

class CoverageObservation {
  const CoverageObservation({required this.point, required this.rssi,
    required this.snr, required this.time});
  final GpsPoint point;
  final int rssi;
  final double snr;
  final DateTime time;
  Map<String, Object> toJson() => {'point': point.toJson(), 'rssi': rssi,
    'snr': snr, 'time': time.toUtc().toIso8601String()};
  factory CoverageObservation.fromJson(Map<String, dynamic> json) => CoverageObservation(
    point: GpsPoint.fromJson(json['point'] as Map<String, dynamic>),
    rssi: json['rssi'] as int, snr: (json['snr'] as num).toDouble(),
    time: DateTime.parse(json['time'] as String));
}

class MappingSession {
  const MappingSession(
      {required this.id,
      required this.started,
      required this.ended,
      required this.points, this.observations = const []});
  final String id;
  final DateTime started;
  final DateTime ended;
  final List<GpsPoint> points;
  final List<CoverageObservation> observations;
  Map<String, Object> toJson() => {
        'id': id,
        'started': started.toUtc().toIso8601String(),
        'ended': ended.toUtc().toIso8601String(),
        'points': points.map((p) => p.toJson()).toList(),
        'observations': observations.map((p) => p.toJson()).toList()
      };
  factory MappingSession.fromJson(Map<String, dynamic> json) => MappingSession(
        id: json['id'] as String,
        started: DateTime.parse(json['started'] as String),
        ended: DateTime.parse(json['ended'] as String),
        observations: List.unmodifiable((json['observations'] as List<dynamic>? ?? []).map(
          (p) => CoverageObservation.fromJson(p as Map<String, dynamic>))),
        points: List.unmodifiable((json['points'] as List<dynamic>)
            .map((p) => GpsPoint.fromJson(p as Map<String, dynamic>))),
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
