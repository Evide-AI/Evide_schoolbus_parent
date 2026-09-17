import 'package:flutter/material.dart';
import '../theme.dart';

// In-app branded splash. Shown briefly after Flutter starts (right after the
// native splash), while we settle the auth state, so the handoff into the app
// feels smooth rather than a sudden jump.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Logo(),
            SizedBox(height: 28),
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();
  @override
  Widget build(BuildContext context) {
    return Image.asset('assets/evide-logo.png', width: 220);
  }
}
