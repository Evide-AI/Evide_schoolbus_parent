import 'dart:async';
import 'package:evide_school_parent/screens/battery_setup_screen.dart';
import 'package:evide_school_parent/screens/login_screen.dart';
import 'package:evide_school_parent/screens/map_screen.dart';
import 'package:evide_school_parent/screens/splash_screen.dart';
import 'package:evide_school_parent/services/battery_service.dart';
import 'package:evide_school_parent/services/parent_service.dart';
import 'package:evide_school_parent/services/push_service.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


/// Shows the splash briefly, then routes to Login or Map based on auth state.
/// Push wiring happens on login/logout events — never inside build().
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final _service = ParentService();
  StreamSubscription<AuthState>? _authSub;

  Session? _session = Supabase.instance.client.auth.currentSession;
  bool _splashDone = false;
  bool _showBatterySetup = false;

  @override
  void initState() {
    super.initState();

    // Hold the branded splash long enough to actually be seen.
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _splashDone = true);
    });

    if (_session != null) {
      PushService.instance.attach(_service);
      _checkBatterySetup();
    }

    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      final session = state.session;
      if (session != null) {
        PushService.instance.attach(_service);
        _checkBatterySetup();
      } else {
        PushService.instance.detach(service: _service);
      }
      if (mounted) setState(() => _session = session);
    });
  }

  /// On Android, asks the parent to fix any setting that would stop alarms
  /// reaching a closed app. Re-prompts at most every 3 days after a skip.
  Future<void> _checkBatterySetup() async {
    if (await BatteryService.instance.shouldPrompt() && mounted) {
      setState(() => _showBatterySetup = true);
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_splashDone) return const SplashScreen();
    if (_session == null) return const LoginScreen();
    if (_showBatterySetup) {
      return BatterySetupScreen(onDone: () => setState(() => _showBatterySetup = false));
    }
    return const MapScreen();
  }
}
