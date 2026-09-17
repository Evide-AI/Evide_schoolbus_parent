import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'config.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/map_screen.dart';
import 'screens/splash_screen.dart';
import 'services/parent_service.dart';
import 'services/alarm_service.dart';

// Background/terminated FCM handler. Must be a top-level function.
// The system shows the notification automatically on the high-importance
// 'proximity_alarm' channel (created in AlarmService.init) so it rings even
// when the app is closed.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // No custom work needed here for the MVP — the platform displays the push on
  // the alarm channel. Kept as a hook for future background logic.
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  // Firebase is optional at startup — if google-services.json isn't added yet,
  // the app still runs (map, tracking work); only push/alarm is disabled.
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);
    await AlarmService().init();
  } catch (e) {
    debugPrint('Firebase not configured yet — push disabled: $e');
  }

  runApp(const ParentApp());
}

class ParentApp extends StatelessWidget {
  const ParentApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Evide Parent',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _service = ParentService();
  bool _fcmWired = false;
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    // Hold the branded splash for a guaranteed moment so it's actually seen,
    // then reveal login/map. Without this, a logged-in user skips straight past
    // it and never sees the splash.
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _splashDone = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_splashDone) return const SplashScreen();
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SplashScreen();
        }
        final session = Supabase.instance.client.auth.currentSession;
        if (session != null) {
          _wireFcm(); // register token + foreground handler once signed in
          return const MapScreen();
        }
        _fcmWired = false;
        return const LoginScreen();
      },
    );
  }

  // Registers this device's FCM token and wires the foreground alarm handler.
  Future<void> _wireFcm() async {
    if (_fcmWired) return;
    _fcmWired = true;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      if (token != null) {
        final platform = Platform.isIOS ? 'ios' : 'android';
        await _service.registerDeviceToken(token, platform);
      }
      messaging.onTokenRefresh.listen((t) {
        final platform = Platform.isIOS ? 'ios' : 'android';
        _service.registerDeviceToken(t, platform);
      });

      // Foreground messages: ring the alarm ourselves (the OS won't auto-show
      // a notification while the app is open).
      FirebaseMessaging.onMessage.listen((RemoteMessage m) {
        final isAlarm = (m.data['type'] ?? '') == 'PROXIMITY_ALARM';
        final title = m.notification?.title ?? 'Evide School Bus';
        final body = m.notification?.body ?? '';
        if (isAlarm) {
          AlarmService().ringForeground(title: title, body: body);
        }
      });
    } catch (e) {
      debugPrint('FCM wiring skipped (Firebase not ready): $e');
    }
  }
}
