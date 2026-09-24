import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// The proximity alarm: a loud, high-priority notification with the alarm tone,
/// shown whether the app is open, in the background, or closed.
///
/// How the sound works on Android: from Android 8 the SOUND IS A PROPERTY OF
/// THE CHANNEL, not of each notification, and a channel's settings are frozen
/// once created. That's why the channel id carries a version — bumping it is
/// the only way to change the tone for people who already have the app.
/// The backend must send this exact id (see notificationWorker.js).
class AlarmService {
  static final AlarmService _instance = AlarmService._();
  factory AlarmService() => _instance;
  AlarmService._();

  final _player = AudioPlayer();
  final _localNotifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Bump the suffix if you ever change the sound or importance below.
  static const alarmChannelId = 'proximity_alarm_v2';
  static const alarmChannelName = 'Bus approaching alerts';
  static const generalChannelId = 'general';

  /// Needs android/app/src/main/res/raw/alarm.mp3 to exist.
  static const _alarmSound = RawResourceAndroidNotificationSound('alarm');

  Future<void> init() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    final android = _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    // Alarm channel: max importance, alarm tone, vibration. Treated as an alarm
    // by the system so it stays audible in Do Not Disturb's alarm exception.
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      alarmChannelId,
      alarmChannelName,
      description: 'Rings when your child\u2019s bus is near the pickup or drop point.',
      importance: Importance.max,
      playSound: true,
      sound: _alarmSound,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      enableLights: true,
    ));

    // Everything else (bus started, school notices) stays quiet by comparison.
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      generalChannelId,
      'Bus updates',
      description: 'Trip start and end, and notices from your school.',
      importance: Importance.defaultImportance,
    ));

    // Android 13+ needs the runtime permission before anything can be shown.
    await android?.requestNotificationsPermission();

    _initialized = true;
  }

  /// Shown when an alarm arrives while the app is on screen. Android suppresses
  /// FCM's own notification in that case, so the app raises it instead.
  Future<void> ringForeground({required String title, required String body}) async {
    await init();

    // The bundled tone, for the in-app case. The channel handles the sound when
    // the notification comes from the system instead.
    try {
      await _player.setVolume(1.0);
      await _player.play(AssetSource('alarm.mp3'));
    } catch (e) {
      debugPrint('Alarm tone skipped: $e');
    }

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          alarmChannelId,
          alarmChannelName,
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          playSound: true,
          sound: _alarmSound,
          audioAttributesUsage: AudioAttributesUsage.alarm,
          enableVibration: true,
          fullScreenIntent: true,
          visibility: NotificationVisibility.public,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          sound: 'alarm.caf',
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
    );
  }

  Future<void> stop() async {
    try { await _player.stop(); } catch (_) {}
  }
}
