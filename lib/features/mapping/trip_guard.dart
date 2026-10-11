import 'dart:math' as math;

import 'mapping_service.dart';

/// Altitude above which a fix is treated as airborne, in metres.
const aircraftAltitudeMetres = 6000.0;

/// Ground speed above which a fix is treated as airborne: 250 km/h in m/s.
const aircraftSpeedMetresPerSecond = 250 / 3.6;

/// Great-circle distance between two fixes in metres.
double distanceMetres(GpsPoint a, GpsPoint b) {
  const earthRadius = 6371000.0;
  double rad(double degrees) => degrees * math.pi / 180;
  final dLat = rad(b.latitude - a.latitude);
  final dLon = rad(b.longitude - a.longitude);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.latitude)) *
          math.cos(rad(b.latitude)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
}

/// Speed for [point] in m/s: the reported speed, else derived from [previous]
/// when the fixes are at least 10 s apart (closer fixes jump too much).
double? effectiveSpeed(GpsPoint point, GpsPoint? previous) {
  final reported = point.speed;
  if (reported != null && reported.isFinite && reported >= 0) return reported;
  if (previous == null) return null;
  final seconds = point.time.difference(previous.time).inMilliseconds / 1000;
  if (seconds < 10) return null;
  return distanceMetres(previous, point) / seconds;
}

/// Whether [point] looks like a fix from an aircraft rather than the ground.
bool isAirborne(GpsPoint point, GpsPoint? previous) {
  final altitude = point.altitude;
  if (altitude != null &&
      altitude.isFinite &&
      altitude > aircraftAltitudeMetres) {
    return true;
  }
  final speed = effectiveSpeed(point, previous);
  return speed != null && speed > aircraftSpeedMetresPerSecond;
}

/// Tracks where the recording last moved, for auto-stop when parked.
class ParkedTracker {
  ParkedTracker({this.radiusMetres = 30});
  final double radiusMetres;
  GpsPoint? _anchor;
  DateTime? _since;

  /// Time the phone settled at its current spot, or null before the first fix.
  DateTime? get settledSince => _since;

  /// Records a new fix; moving beyond the radius restarts the parked timer.
  void add(GpsPoint point) {
    final anchor = _anchor;
    if (anchor == null || distanceMetres(anchor, point) > radiusMetres) {
      _anchor = point;
      _since = point.time;
    }
  }

  /// Whether the phone has stayed put for at least [limit] as of [now].
  bool parked(DateTime now, Duration limit) {
    final since = _since;
    return since != null &&
        !now.difference(since).isNegative &&
        now.difference(since) >= limit;
  }

  void reset() {
    _anchor = null;
    _since = null;
  }
}
