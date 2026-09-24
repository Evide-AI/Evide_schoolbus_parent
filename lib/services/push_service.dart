import 'dart:async';
import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import '../firebase_options.dart';
import 'alarm_service.dart';
import 'parent_service.dart';

/// Handles pushes that arrive while the app is in the background or closed.
/// Must be a top-level function, and it runs in its own isolate, so Firebase
/// has to be initialised again here.
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }
    // A push carrying a `notification` block is drawn by Android itself on the
    // channel the backend names. Only a data-only push needs us to draw it.
    final isAlarm = (message.data['type'] ?? '') == 'PROXIMITY_ALARM';
    if (message.notification == null && isAlarm) {
      await AlarmService().ringForeground(
        title: message.data['title'] ?? 'Bus is approaching',
        body: message.data['body'] ?? '',
      );
    }
  } catch (e) {
    debugPrint('Background push handling failed: $e');
  }
}

/// Owns everything Firebase/FCM: init, permission, token registration, alarm.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final Completer<bool> _ready = Completer<bool>();
  bool _attached = false;
  StreamSubscription<RemoteMessage>? _msgSub;
  StreamSubscription<String>? _tokenSub;

  /// Called once at startup.
  Future<void> init() async {
    if (_ready.isCompleted) return;
    try {
      // Options come from firebase_options.dart. Without them, Android falls
      // back to google-services.json — and if that file is missing from the
      // build, initialisation throws and push dies silently.
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      }
      FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
      await AlarmService().init();
      _ready.complete(true);
      debugPrint('[Push] Firebase ready.');
    } catch (e) {
      debugPrint('[Push] Firebase init FAILED — notifications are off: $e');
      _ready.complete(false);
    }
  }

  /// Called after login: asks permission, saves the device token, and listens
  /// for alarms while the app is open.
  Future<void> attach(ParentService service) async {
    if (_attached) return;
    _attached = true;

    if (!await _ready.future) return;

    try {
      final messaging = FirebaseMessaging.instance;

      final settings = await messaging.requestPermission(
        alert: true, badge: true, sound: true,
      );
      debugPrint('[Push] permission: ${settings.authorizationStatus}');
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        // Nothing can be delivered until the parent turns notifications on in
        // Android settings, so don't pretend otherwise in the logs.
        debugPrint('[Push] Notifications denied — alarms will not be shown.');
      }

      final platform = Platform.isIOS ? 'ios' : 'android';

      // iOS won't hand out a token until APNs has registered the device.
      if (Platform.isIOS) {
        await messaging.getAPNSToken();
      }

      final token = await messaging.getToken();
      if (token != null) {
        await service.registerDeviceToken(token, platform);
        debugPrint('[Push] token saved (${token.substring(0, 12)}…)');
      } else {
        debugPrint('[Push] No FCM token returned.');
      }

      // Tokens rotate on reinstall, data clear, or restore. Without this the
      // backend keeps pushing to a dead token and nothing ever arrives.
      _tokenSub = messaging.onTokenRefresh.listen((t) async {
        await service.registerDeviceToken(t, platform);
        debugPrint('[Push] token refreshed.');
      });

      // Foreground: Android suppresses FCM's own notification, so ring here.
      _msgSub = FirebaseMessaging.onMessage.listen((m) {
        if ((m.data['type'] ?? '') == 'PROXIMITY_ALARM') {
          AlarmService().ringForeground(
            title: m.notification?.title ?? m.data['title'] ?? 'Bus is approaching',
            body: m.notification?.body ?? m.data['body'] ?? '',
          );
        }
      });
    } catch (e) {
      debugPrint('[Push] wiring failed: $e');
    }
  }

  /// Removes this device's token so a signed-out phone stops receiving alarms.
  Future<void> detach({ParentService? service}) async {
    await _msgSub?.cancel();
    await _tokenSub?.cancel();
    _msgSub = null;
    _tokenSub = null;
    _attached = false;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && service != null) await service.removeDeviceToken(token);
    } catch (_) {/* signing out shouldn't fail over this */}
  }
}
