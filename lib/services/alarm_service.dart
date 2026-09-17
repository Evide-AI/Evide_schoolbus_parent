import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Handles the proximity alarm: plays a sound in the foreground and shows a
// high-priority local notification. Background/killed alarms are delivered by
// FCM (see main.dart's background handler) on the same 'proximity_alarm'
// channel so the phone rings even when the app isn't open.
class AlarmService {
  static final AlarmService _instance = AlarmService._();
  factory AlarmService() => _instance;
  AlarmService._();

  final _player = AudioPlayer();
  final _localNotifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const alarmChannelId = 'proximity_alarm';

  Future<void> init() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await _localNotifications.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    // High-importance channel so the notification pops and plays sound even in
    // the background. NOTE: to use a CUSTOM alarm sound, add a sound file at
    // android/app/src/main/res/raw/alarm.mp3 and set `sound:` below to
    // RawResourceAndroidNotificationSound('alarm'). Left as default here so it
    // works out-of-the-box before you add a sound asset.
    const channel = AndroidNotificationChannel(
      alarmChannelId,
      'Bus approaching alerts',
      description: 'Rings when your child\u2019s bus is near the pickup or drop point.',
      importance: Importance.max,
      playSound: true,
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _initialized = true;
  }

  /// Called when a proximity alarm arrives while the app is in the foreground.
  Future<void> ringForeground({required String title, required String body}) async {
    await init();
    // Play the alarm tone. Uses a bundled asset if present; otherwise this is a
    // no-op that won't crash. Add assets/alarm.mp3 and register it in pubspec
    // to enable the custom tone.
    try {
      await _player.play(AssetSource('alarm.mp3'));
    } catch (_) {/* no custom sound asset yet */}

    await _localNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          alarmChannelId,
          'Bus approaching alerts',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(presentSound: true),
      ),
    );
  }

  Future<void> stop() async {
    try { await _player.stop(); } catch (_) {}
  }
}
