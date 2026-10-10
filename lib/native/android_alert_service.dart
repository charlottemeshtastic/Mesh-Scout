import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../features/alerts/message_alerts.dart';

class AndroidAlertService implements AlertService {
  static const _channel = MethodChannel('org.meshscout/message_alerts');
  @override
  Future<bool> load() async =>
      await _channel.invokeMethod<bool>('load') ?? false;
  @override
  Future<bool> configure(bool enabled) async {
    if (enabled && !(await Permission.notification.request()).isGranted) {
      await _channel.invokeMethod<bool>('configure', false);
      return false;
    }
    return await _channel.invokeMethod<bool>('configure', enabled) ?? false;
  }

  @override
  Future<void> waiting() => _channel.invokeMethod<void>('waiting');
  @override
  Future<bool> consumeOpen() async =>
      await _channel.invokeMethod<bool>('consumeOpen') ?? false;
  @override
  Future<void> clear() => _channel.invokeMethod<void>('clear');
}
