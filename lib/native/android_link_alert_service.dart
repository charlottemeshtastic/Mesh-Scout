import 'package:flutter/services.dart';
import '../features/alerts/link_alerts.dart';

/// Android notification-channel alert for a dropped radio link.
class AndroidLinkAlertService implements LinkAlertService {
  static const _channel = MethodChannel('org.meshscout/link_alerts');
  @override
  Future<void> lost(String? name) => _channel.invokeMethod<void>('lost', name);
  @override
  Future<void> restored() => _channel.invokeMethod<void>('restored');
}
