import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'alarm_service.dart';

/// What is currently stopping alarms from reaching this phone.
class AlarmReadiness {
  final bool notificationsOn;
  final bool alarmChannelOn;
  final bool batteryUnrestricted;
  final String manufacturer;

  const AlarmReadiness({
    required this.notificationsOn,
    required this.alarmChannelOn,
    required this.batteryUnrestricted,
    required this.manufacturer,
  });

  bool get allGood => notificationsOn && alarmChannelOn && batteryUnrestricted;

  /// Brands whose own battery manager stops apps the OS would otherwise allow.
  bool get needsAutostartStep => const [
        'xiaomi', 'redmi', 'poco', 'oppo', 'realme', 'oneplus',
        'vivo', 'iqoo', 'huawei', 'honor', 'samsung',
      ].contains(manufacturer);
}

/// Checks and fixes the phone settings that decide whether a push can reach a
/// closed app. See BatterySetupScreen for the UI.
class BatteryService {
  BatteryService._();
  static final BatteryService instance = BatteryService._();

  static const _channel = MethodChannel('in.evide.parent/battery');
  static const _skipKey = 'battery_setup_skipped_at';

  /// Only Android has these problems. iOS manages background delivery itself.
  bool get supported => !kIsWeb && Platform.isAndroid;

  Future<AlarmReadiness> check() async {
    var notificationsOn = true;
    var alarmChannelOn = true;
    var battery = true;
    var maker = '';

    try {
      final android = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      notificationsOn = await android?.areNotificationsEnabled() ?? true;

      final channels = await android?.getNotificationChannels();
      final alarm = channels?.where((c) => c.id == AlarmService.alarmChannelId);
      if (alarm != null && alarm.isNotEmpty) {
        // The parent can silence a channel from system settings.
        alarmChannelOn = alarm.first.importance.value >= Importance.high.value;
      }
    } catch (e) {
      debugPrint('[Battery] notification check failed: $e');
    }

    try {
      battery = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? true;
      maker = await _channel.invokeMethod<String>('manufacturer') ?? '';
    } catch (e) {
      debugPrint('[Battery] battery check failed: $e');
    }

    return AlarmReadiness(
      notificationsOn: notificationsOn,
      alarmChannelOn: alarmChannelOn,
      batteryUnrestricted: battery,
      manufacturer: maker,
    );
  }

  Future<void> openBatterySettings() async {
    try {
      await _channel.invokeMethod('openBatteryOptimizationSettings');
    } catch (e) {
      debugPrint('[Battery] open battery settings failed: $e');
    }
  }

  Future<void> openAutostartSettings() async {
    try {
      await _channel.invokeMethod('openAutostartSettings');
    } catch (e) {
      debugPrint('[Battery] open autostart settings failed: $e');
    }
  }

  Future<void> openAlarmChannelSettings() async {
    try {
      await _channel.invokeMethod('openAlarmChannelSettings');
    } catch (e) {
      debugPrint('[Battery] open channel settings failed: $e');
    }
  }

  Future<void> openNotificationSettings() async {
    // Asks for the runtime permission (Android 13+).
    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  /// Whether to put the setup screen in front of the parent. Shown whenever
  /// something is wrong, but not more than once every 3 days if they skip it.
  Future<bool> shouldPrompt() async {
    if (!supported) return false;
    final r = await check();
    if (r.allGood) return false;
    final prefs = await SharedPreferences.getInstance();
    final skippedAt = prefs.getInt(_skipKey);
    if (skippedAt == null) return true;
    final since = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(skippedAt));
    return since > const Duration(days: 3);
  }

  Future<void> markSkipped() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_skipKey, DateTime.now().millisecondsSinceEpoch);
  }
}
