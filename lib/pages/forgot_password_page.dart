import 'dart:async';

import 'package:first/utils/auth_login.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  static const String _resetRedirectUrl = String.fromEnvironment(
    'PASSWORD_RESET_REDIRECT_URL',
    defaultValue: '',
  );
  static final RegExp _emailRegex = RegExp(
    r'^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$',
    caseSensitive: false,
  );
  static const Duration _requestTimeout = Duration(seconds: 15);
  static const Duration _resendCooldown = Duration(seconds: 30);

  final TextEditingController _emailController = TextEditingController();
  bool _isLoading = false;
  DateTime? _lastSentAt;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  bool _isInCooldown() {
    final last = _lastSentAt;
    if (last == null) return false;
    return DateTime.now().difference(last) < _resendCooldown;
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

  Future<void> _sendResetLink() async {
    if (_isLoading) return;

    final email = normalizeAuthIdentifier(_emailController.text);
    if (email.isEmpty || !_emailRegex.hasMatch(email)) {
      _showBanner(kRegistrationEmailInvalid);
      return;
    }
    if (_isInCooldown()) {
      _showBanner('Please wait a few seconds before requesting again.');
      return;
    }

    setState(() => _isLoading = true);
    try {
      final client = Supabase.instance.client;

      await client.auth
          .resetPasswordForEmail(
            email,
            redirectTo: _resetRedirectUrl.isNotEmpty ? _resetRedirectUrl : null,
          )
          .timeout(_requestTimeout);

      _lastSentAt = DateTime.now();
      _showBanner(
        'If an account exists for this email, a password reset link has been sent.',
        success: true,
      );
    } on TimeoutException {
      _showBanner('Request timed out. Check your connection and try again.');
    } on AuthException catch (_) {
      // Keep a generic response to avoid account enumeration.
      _lastSentAt = DateTime.now();
      _showBanner(
        'If an account exists for this email, a password reset link has been sent.',
        success: true,
      );
    } catch (_) {
      _showBanner('Unable to send reset link right now. Please try again later.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () {
            Navigator.pop(context); // Goes back to the Login page
          },
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              // Lock/Reset Icon
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0xFFE3F2FD), // Light blue background
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock_reset_rounded,
                    size: 50,
                    color: Color(0xFF1A60FF),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Title and Subtitle
              const Center(
                child: Text(
                  'Forgot Password?',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0D1B3E),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Enter the email address associated with your account and we will send you a link to reset your password.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: Colors.blueGrey[600],
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 40),

              // Email Input Field
              const Text(
                'Email',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _sendResetLink(),
                decoration: InputDecoration(
                  hintText: 'your.email@example.com',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  filled: true,
                  fillColor: const Color(0xFFF5F7F9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Send Reset Link Button
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _sendResetLink,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A60FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Send Reset Link',
                          style: TextStyle(
                            fontSize: 18,
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
