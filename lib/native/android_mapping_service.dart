import 'dart:io';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../features/mapping/mapping_service.dart';

class AndroidMappingService implements MappingService, BackgroundMappingService {
  static const _methods = MethodChannel('org.meshscout/mapping');
  bool _background = false;
  DateTime? _started;
  @override
  Future<void> configureRecording(bool background, DateTime started) async {
    _background = background;
    _started = started;
    if (background) await Permission.notification.request();
  }
  static const _events = EventChannel('org.meshscout/positions');

  @override
  Future<void> authorize() async {
    if (!Platform.isAndroid) {
      throw Exception('GPS recording is available on Android.');
    }
    final status = await Permission.locationWhenInUse.request();
    if (!status.isGranted) {
      throw Exception(
          'Location permission is required. Enable precise location in App permissions.');
    }
    final enabled = await _methods.invokeMethod<bool>('locationEnabled');
    if (enabled != true) {
      throw Exception('Enable GPS/location services and try again.');
    }
  }

  @override
  Stream<GpsPoint> positions() => _events.receiveBroadcastStream({'background': _background, 'started': _started?.microsecondsSinceEpoch}).map((event) {
        final data = event as Map<dynamic, dynamic>;
        return GpsPoint(
            (data['lat'] as num).toDouble(),
            (data['lon'] as num).toDouble(),
            (data['accuracy'] as num).toDouble(),
            DateTime.fromMillisecondsSinceEpoch((data['time'] as num).toInt(),
                isUtc: true));
      });
  @override
  Future<String?> load() => _methods.invokeMethod<String>('loadSessions');
  @override
  Future<void> save(String json) =>
      _methods.invokeMethod<void>('saveSessions', json);
}
