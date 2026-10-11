import 'dart:convert';

import 'package:flutter/services.dart';

import '../mapping/mapping_service.dart';

enum ExportFormat { geoJson, csv }

String exportSession(MappingSession session, ExportFormat format) {
  if (format == ExportFormat.csv) {
    final rows = <List<Object>>[
      [
        'kind',
        'time_utc',
        'latitude',
        'longitude',
        'accuracy_m',
        'altitude_m',
        'rssi_dbm',
        'snr_db',
      ],
      for (final p in session.points)
        [
          session.planned ? 'planned_route_point' : 'gps',
          session.planned ? '' : p.time.toUtc().toIso8601String(),
          p.latitude,
          p.longitude,
          session.planned ? '' : p.accuracy,
          session.planned ? '' : p.altitude ?? '',
          '',
          '',
        ],
      for (final o in session.observations)
        [
          'raw_lora_rx',
          o.time.toUtc().toIso8601String(),
          o.point.latitude,
          o.point.longitude,
          o.point.accuracy,
          o.point.altitude ?? '',
          o.rssi,
          o.snr,
        ],
    ];
    return rows
        .map(
          (r) =>
              r.map((v) => '"${v.toString().replaceAll('"', '""')}"').join(','),
        )
        .join('\r\n');
  }
  return jsonEncode({
    'type': 'FeatureCollection',
    'properties': {
      'session_id': session.id,
      'planned_route': session.planned,
      if (session.name != null) 'session_name': session.name,
      'started': session.started.toUtc().toIso8601String(),
      'ended': session.ended.toUtc().toIso8601String(),
      'measurement_note':
          'Raw last-hop reception; sender identity and delivery unverified.',
    },
    'features': [
      if (session.points.length >= 2)
        {
          'type': 'Feature',
          'properties': {'kind': 'route'},
          'geometry': {
            'type': 'LineString',
            'coordinates': [
              for (final p in session.points) [p.longitude, p.latitude],
            ],
          },
        },
      for (final p in session.points)
        {
          'type': 'Feature',
          'properties': {
            'kind': session.planned ? 'planned_route_point' : 'gps',
            if (!session.planned) 'time_utc': p.time.toUtc().toIso8601String(),
            if (!session.planned) 'accuracy_m': p.accuracy,
            if (!session.planned && p.altitude != null)
              'altitude_m': p.altitude,
          },
          'geometry': {
            'type': 'Point',
            'coordinates': [p.longitude, p.latitude],
          },
        },
      for (final o in session.observations)
        {
          'type': 'Feature',
          'properties': {
            'kind': 'raw_lora_rx',
            'time_utc': o.time.toUtc().toIso8601String(),
            'gps_time_utc': o.point.time.toUtc().toIso8601String(),
            'accuracy_m': o.point.accuracy,
            if (o.point.altitude != null) 'altitude_m': o.point.altitude,
            'rssi_dbm': o.rssi,
            'snr_db': o.snr,
          },
          'geometry': {
            'type': 'Point',
            'coordinates': [o.point.longitude, o.point.latitude],
          },
        },
    ],
  });
}

class SessionExportService {
  static const channel = MethodChannel('org.meshscout/files');
  Future<bool> send(
    MappingSession session,
    ExportFormat format, {
    required bool share,
  }) async {
    final extension = format == ExportFormat.csv ? 'csv' : 'geojson';
    return await channel.invokeMethod<bool>(share ? 'share' : 'save', {
          'name':
              'MeshScout-${session.started.toUtc().millisecondsSinceEpoch}.$extension',
          'mime':
              format == ExportFormat.csv ? 'text/csv' : 'application/geo+json',
          'content': exportSession(session, format),
        }) ??
        false;
  }
}
