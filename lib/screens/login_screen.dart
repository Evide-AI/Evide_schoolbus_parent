import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/parent_service.dart';
import '../theme.dart';
import 'forgot_password_screen.dart';

enum _LoginMode { phone, email }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _service = ParentService();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  // Most parents were given a phone login, so that's the default.
  _LoginMode _mode = _LoginMode.phone;
  bool _submitting = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  bool get _phoneLooksValid =>
      RegExp(r'^[6-9]\d{9}$').hasMatch(_phoneCtrl.text.replaceAll(RegExp(r'\D'), ''));

  Future<void> _signIn() async {
    if (_mode == _LoginMode.phone && !_phoneLooksValid) {
      setState(() => _error = 'Enter your 10-digit mobile number.');
      return;
    }
    if (_passwordCtrl.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (_mode == _LoginMode.phone) {
        await _service.signInWithPhone(
          phone: _phoneCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
      } else {
        await Supabase.instance.client.auth.signInWithPassword(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
      }
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

  void _switchMode(_LoginMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _error = null;
    });
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
                  const SizedBox(height: 22),

                  _ModeSwitch(mode: _mode, onChanged: _submitting ? null : _switchMode),
                  const SizedBox(height: 18),

                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: AppColors.stopSoft, borderRadius: BorderRadius.circular(8)),
                      child: Text(_error!, style: const TextStyle(color: AppColors.stop)),
                    ),
                    const SizedBox(height: 16),
                  ],

                  if (_mode == _LoginMode.phone)
                    TextField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Mobile number',
                        prefixText: '+91 ',
                      ),
                    )
                  else
                    TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),

                  const SizedBox(height: 14),
                  TextField(
                    controller: _passwordCtrl,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
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
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => const ForgotPasswordScreen(),
                            )),
                    child: const Text('Forgot password?'),
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

/// Phone / Email toggle above the sign-in fields.
class _ModeSwitch extends StatelessWidget {
  final _LoginMode mode;
  final ValueChanged<_LoginMode>? onChanged;
  const _ModeSwitch({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.paper,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          _tab(_LoginMode.phone, 'Mobile number', Icons.phone_iphone_rounded),
          _tab(_LoginMode.email, 'Email', Icons.alternate_email_rounded),
        ],
      ),
    );
  }

  Widget _tab(_LoginMode value, String label, IconData icon) {
    final selected = mode == value;
    return Expanded(
      child: GestureDetector(
        onTap: onChanged == null ? null : () => onChanged!(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected
                ? const [BoxShadow(color: Color(0x14202B49), blurRadius: 6, offset: Offset(0, 2))]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: selected ? AppColors.accent : AppColors.inkFaint),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppColors.ink : AppColors.inkFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
