import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/parent_service.dart';
import '../theme.dart';

/// Lets a signed-in parent set their own password, so they don't have to keep
/// the one the school sent them on WhatsApp.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _service = ParentService();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _obscure = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pw = _newCtrl.text;
    if (pw.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }
    if (pw != _confirmCtrl.text) {
      setState(() => _error = 'The two passwords don\u2019t match.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _service.updatePassword(pw);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed.')),
      );
      Navigator.of(context).pop();
    } on AuthException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not change the password. Check your connection and try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change password')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Choose a new password',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'You\u2019ll use this the next time you sign in.',
                    style: TextStyle(color: AppColors.inkFaint),
                  ),
                  const SizedBox(height: 24),
                  if (_error != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.stopSoft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!, style: const TextStyle(color: AppColors.stop)),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    controller: _newCtrl,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      labelText: 'New password',
                      helperText: 'At least 8 characters',
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _confirmCtrl,
                    obscureText: _obscure,
                    decoration: const InputDecoration(labelText: 'Repeat new password'),
                    onSubmitted: (_) => _saving ? null : _save(),
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    child: Text(_saving ? 'Saving\u2026' : 'Save password'),
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
