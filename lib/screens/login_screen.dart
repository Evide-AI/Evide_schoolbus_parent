import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() { _submitting = true; _error = null; });
    try {
      await Supabase.instance.client.auth.signInWithPassword(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
      );
    } on AuthException catch (e) {
      setState(() {
        _error = e.message == 'Invalid login credentials'
            ? 'Email or password is incorrect.'
            : e.message;
        _submitting = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Something went wrong. Check your connection and try again.';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.line),
                    ),
                    child: Image.asset('assets/evide-logo.png', height: 44),
                  ),
                  const SizedBox(height: 24),
                  const Text('Track your child',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: AppColors.ink)),
                  const SizedBox(height: 6),
                  const Text('Sign in to see your child\u2019s bus in real time.',
                      style: TextStyle(color: AppColors.inkFaint)),
                  const SizedBox(height: 28),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: AppColors.stopSoft, borderRadius: BorderRadius.circular(8)),
                      child: Text(_error!, style: const TextStyle(color: AppColors.stop)),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _emailCtrl,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                    onSubmitted: (_) => _submitting ? null : _signIn(),
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _submitting ? null : _signIn,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: Text(_submitting ? 'Signing in\u2026' : 'Sign in'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
