import 'package:flutter/material.dart';
import '../services/parent_service.dart';
import '../theme.dart';

/// "Forgot password" for parents.
///
/// Parents have no email inbox tied to their login and we don't send SMS, so
/// the request goes to the school office instead: they reset the password from
/// the management dashboard and send the new one on WhatsApp.
///
/// The screen never says whether an account exists — that would let anyone
/// check which numbers are registered — so every valid submission shows the
/// same confirmation.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _service = ParentService();
  final _identifierCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  bool _submitting = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final identifier = _identifierCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    if (identifier.isEmpty) {
      setState(() => _error = 'Enter the email or phone number you sign in with.');
      return;
    }
    if (phone.replaceAll(RegExp(r'\D'), '').length < 10) {
      setState(() => _error = 'Enter a 10-digit mobile number the school can reach you on.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _service.requestPasswordReset(identifier: identifier, contactPhone: phone);
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not send the request. Check your connection and try again.';
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot password')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: _sent ? _sentView() : _formView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sentView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle_rounded, size: 56, color: AppColors.go),
        const SizedBox(height: 18),
        const Text(
          'Request sent',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink),
        ),
        const SizedBox(height: 10),
        const Text(
          'Your school office will set a new password and send it to you on WhatsApp. '
          'This usually happens on the next working day.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.inkSoft, height: 1.5),
        ),
        const SizedBox(height: 26),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            padding: const EdgeInsets.symmetric(vertical: 15),
          ),
          child: const Text('Back to sign in'),
        ),
      ],
    );
  }

  Widget _formView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Ask your school for a new password',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink),
        ),
        const SizedBox(height: 8),
        const Text(
          'The school office will set a new password and send it to you on WhatsApp.',
          style: TextStyle(color: AppColors.inkFaint, height: 1.5),
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
          controller: _identifierCtrl,
          autocorrect: false,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email or phone you sign in with',
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'WhatsApp number',
            prefixText: '+91 ',
            helperText: 'The school sends the new password here.',
          ),
        ),
        const SizedBox(height: 22),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            padding: const EdgeInsets.symmetric(vertical: 15),
          ),
          child: Text(_submitting ? 'Sending\u2026' : 'Send request to school'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Back to sign in'),
        ),
      ],
    );
  }
}
