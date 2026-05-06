import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/password_policy.dart';
import '../widgets/password_confirm_match_panel.dart';
import '../widgets/password_requirements_panel.dart';
import 'login_page.dart';

class PasswordRecoveryPage extends StatefulWidget {
  const PasswordRecoveryPage({super.key});

  @override
  State<PasswordRecoveryPage> createState() => _PasswordRecoveryPageState();
}

class _PasswordRecoveryPageState extends State<PasswordRecoveryPage> {
  static const Duration _requestTimeout = Duration(seconds: 15);

  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();

  bool _saving = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _confirmFocusNode = FocusNode();

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    _passwordFocusNode.dispose();
    _confirmFocusNode.dispose();
    super.dispose();
  }

  void _showBanner(
    String message, {
    bool success = false,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green : Colors.redAccent,
      ),
    );
  }

  Future<void> _submitNewPassword() async {
    if (_saving) return;

    final password = _passwordController.text.trim();
    final confirm = _confirmController.text.trim();
    final validationError = PasswordPolicy.validate(password);
    if (validationError != null) {
      _showBanner(validationError);
      return;
    }
    if (password != confirm) {
      _showBanner('Passwords do not match.');
      return;
    }

    setState(() => _saving = true);
    try {
      await Supabase.instance.client.auth
          .updateUser(
            UserAttributes(password: password),
          )
          .timeout(_requestTimeout);

      if (!mounted) return;
      _showBanner('Password updated. Please sign in with your new password.', success: true);
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (_) => const LoginPage(
            initialBannerText: 'Password updated successfully. Please sign in.',
            initialBannerSuccess: true,
          ),
        ),
        (route) => false,
      );
    } on TimeoutException {
      _showBanner('Request timed out. Check your connection and try again.');
    } on AuthException catch (_) {
      _showBanner('Unable to update password. Open the latest reset link and try again.');
    } catch (_) {
      _showBanner('Unable to update password right now. Please try again later.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Set New Password'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              const Text(
                'Create a new password',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0D1B3E),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                PasswordPolicy.requirementsHint,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.black54,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'New password',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  suffixIcon: IconButton(
                    tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              PasswordRequirementsPanel(
                controller: _passwordController,
                focusNode: _passwordFocusNode,
              ),
              const SizedBox(height: 18),
              const Text(
                'Confirm password',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _confirmController,
                focusNode: _confirmFocusNode,
                obscureText: _obscureConfirm,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitNewPassword(),
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  suffixIcon: IconButton(
                    tooltip: _obscureConfirm ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                    icon: Icon(
                      _obscureConfirm
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              PasswordConfirmMatchPanel(
                passwordController: _passwordController,
                confirmController: _confirmController,
                confirmFocusNode: _confirmFocusNode,
              ),
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _saving ? null : _submitNewPassword,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A60FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Update Password',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
