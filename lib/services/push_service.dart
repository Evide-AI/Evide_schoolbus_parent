import 'dart:async';
import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'alarm_service.dart';
import 'parent_service.dart';

/// Background/terminated FCM handler. Must be top-level.
/// The OS shows the push on the high-importance 'proximity_alarm' channel
/// (created in AlarmService.init), so it rings even when the app is closed.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  // Hook for future background logic.
}

/// Owns everything Firebase/FCM: init, token registration, foreground alarm.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final Completer<bool> _ready = Completer<bool>();
  bool _attached = false;
  StreamSubscription<RemoteMessage>? _msgSub;
  StreamSubscription<String>? _tokenSub;

  /// Safe to call once at startup. If google-services.json isn't set up,
  /// the app still runs — only push/alarm is disabled.
  Future<void> init() async {
    if (_ready.isCompleted) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
      await AlarmService().init();
      _ready.complete(true);
    } catch (e) {
      debugPrint('Firebase not configured yet — push disabled: $e');
      _ready.complete(false);
    }
  }

  /// Call after login. Registers the device token and the foreground alarm.
  /// Guarded so listeners are never registered twice.
  Future<void> attach(ParentService service) async {
    if (_attached) return;
    _attached = true;

    if (!await _ready.future) return;

    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      final platform = Platform.isIOS ? 'ios' : 'android';
      final token = await messaging.getToken();
      if (token != null) await service.registerDeviceToken(token, platform);

      _tokenSub = messaging.onTokenRefresh
          .listen((t) => service.registerDeviceToken(t, platform));

      // Foreground: the OS won't show the push while the app is open,
      // so ring the alarm ourselves.
      _msgSub = FirebaseMessaging.onMessage.listen((m) {
        if ((m.data['type'] ?? '') == 'PROXIMITY_ALARM') {
          AlarmService().ringForeground(
            title: m.notification?.title ?? 'Evide School Bus',
            body: m.notification?.body ?? '',
          );
        }
      });
    } catch (e) {
      debugPrint('FCM wiring skipped: $e');
    }
  }

  /// Call on logout.
  void detach() {
    _msgSub?.cancel();
    _tokenSub?.cancel();
    _msgSub = null;
    _tokenSub = null;
    _attached = false;
  }
}
