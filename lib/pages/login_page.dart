import 'dart:async'; // CRITICAL: This fixes the TimeoutException error
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/auth_login.dart';
import 'register_page.dart';
import 'location_permission_page.dart';
import 'forgot_password_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    this.initialBannerText,
    this.initialBannerSuccess = false,
    this.showEmailVerificationRequired = false,
    this.registeredEmailForResend,
  });

  /// Shown once after navigation (e.g. from registration) so the correct screen owns the snackbar.
  final String? initialBannerText;
  final bool initialBannerSuccess;

  /// Shows the “verify email before sign-in” panel (e.g. after sign-up with confirm-email enabled).
  final bool showEmailVerificationRequired;

  /// Used only for resend and masked display; never shown in full.
  final String? registeredEmailForResend;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with TickerProviderStateMixin {
  final _identifierController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  late bool _showVerificationPanel;
  String? _emailForResend;
  Timer? _resendCooldownTimer;
  int _resendCooldownSeconds = 0;
  bool _resendInFlight = false;
  late final AnimationController _bgController;
  late final AnimationController _entryController;

  @override
  void initState() {
    super.initState();
    _showVerificationPanel = widget.showEmailVerificationRequired;
    final raw = widget.registeredEmailForResend?.trim();
    _emailForResend =
        (raw == null || raw.isEmpty) ? null : normalizeAuthIdentifier(raw);
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();

    final banner = widget.initialBannerText;
    if (banner != null && banner.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(banner),
            backgroundColor: widget.initialBannerSuccess
                ? Colors.green
                : Colors.redAccent,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _resendCooldownTimer?.cancel();
    _identifierController.dispose();
    _passwordController.dispose();
    _bgController.dispose();
    _entryController.dispose();
    super.dispose();
  }

  void _startResendCooldown(int seconds) {
    _resendCooldownTimer?.cancel();
    setState(() => _resendCooldownSeconds = seconds);
    _resendCooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_resendCooldownSeconds <= 1) {
        t.cancel();
        setState(() => _resendCooldownSeconds = 0);
      } else {
        setState(() => _resendCooldownSeconds--);
      }
    });
  }

  Future<void> _resendVerificationEmail() async {
    var email = _emailForResend;
    if (email == null || email.isEmpty) {
      final id = normalizeAuthIdentifier(_identifierController.text);
      if (id.contains('@')) {
        email = id;
      }
    }
    if (email == null || !email.contains('@')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter the email you registered with above, then tap Resend.',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (_resendCooldownSeconds > 0 || _resendInFlight) return;

    setState(() => _resendInFlight = true);
    try {
      await Supabase.instance.client.auth
          .resend(
            type: OtpType.signup,
            email: email,
            emailRedirectTo: emailConfirmRedirectUrl(),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      _emailForResend ??= email;
      _startResendCooldown(60);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Verification email sent. Check your inbox.'),
          backgroundColor: Colors.green,
        ),
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.message.isNotEmpty ? e.message : 'Could not resend email.',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Request timed out. Check your connection.'),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) setState(() => _resendInFlight = false);
    }
  }

  Widget _buildEmailVerificationPanel() {
    final hint = _emailForResend;
    final detail = hint != null && hint.contains('@')
        ? 'We sent a secure link to ${maskEmailForDisplay(hint)}. Open it to verify your account, then sign in below.'
        : 'We sent a verification link to your email. Check your inbox and spam folder, then sign in below.';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(242),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.amber.shade700.withAlpha(180)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.mark_email_unread_outlined,
                color: Colors.amber.shade800,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      kEmailVerificationPanelTitle,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        color: Color(0xFF12305E),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      detail,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.35,
                        color: Color(0xFF334866),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'For your security, you must verify your email before you can log in.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: (_resendCooldownSeconds > 0 || _resendInFlight)
                  ? null
                  : _resendVerificationEmail,
              child: _resendInFlight
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _resendCooldownSeconds > 0
                          ? 'Resend verification email (${_resendCooldownSeconds}s)'
                          : 'Resend verification email',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleLogin() async {
    if (_identifierController.text.isEmpty || _passwordController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter username/email and password'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    String? resolvedEmailForAuth;

    try {
      final client = Supabase.instance.client;
      final identifier = normalizeAuthIdentifier(_identifierController.text);
      String resolvedEmail = identifier;

      // If user typed a username, resolve to email via [profiles] (lowercase [.eq]).
      if (!identifier.contains('@')) {
        try {
          final profile = await client
              .from('profiles')
              .select('email')
              .eq('username', identifier)
              .maybeSingle();
          final emailFromUsername =
              profile?['email']?.toString().trim().toLowerCase();
          if (emailFromUsername == null || emailFromUsername.isEmpty) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(kInvalidLoginCredentials),
                backgroundColor: Colors.redAccent,
              ),
            );
            return;
          }
          resolvedEmail = emailFromUsername;
        } catch (_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(kInvalidLoginCredentials),
              backgroundColor: Colors.redAccent,
            ),
          );
          return;
        }
      }

      final emailForAuth = normalizeAuthIdentifier(resolvedEmail);
      resolvedEmailForAuth = emailForAuth;

      final auth = await client.auth.signInWithPassword(
        email: emailForAuth,
        password: _passwordController.text.trim(),
      ).timeout(const Duration(seconds: 15));

      final user = auth.user;
      if (user == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(kInvalidLoginCredentials),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      final profile = await client
          .from('profiles')
          .select('role')
          .eq('id', user.id)
          .maybeSingle();
      final role = (profile?['role'] ?? '').toString().trim().toLowerCase();

      if (role == 'rescuer' || role == 'admin') {
        await client.auth.signOut();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(kAccessDenied),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const LocationPermissionPage(),
          ),
        );
      }
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Login timed out. Check your connection.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) {
        if (authExceptionIsEmailNotConfirmed(e)) {
          setState(() {
            _showVerificationPanel = true;
            final addr = resolvedEmailForAuth;
            if (addr != null && addr.contains('@')) {
              _emailForResend = addr;
            }
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(loginAuthErrorMessage(e)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(kInvalidLoginCredentials),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0E1E3A),
                  Color(0xFF122D5E),
                  Color(0xFF153C78),
                ],
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) => Stack(
              children: [
                Positioned(
                  top: -110 + (_bgController.value * 35),
                  right: -90,
                  child: _buildGlow(250, Colors.cyanAccent.withAlpha(46)),
                ),
                Positioned(
                  bottom: -120,
                  left: -70 + (_bgController.value * 32),
                  child: _buildGlow(290, Colors.lightBlueAccent.withAlpha(38)),
                ),
              ],
            ),
          ),
          SafeArea(
            child: FadeTransition(
              opacity: CurvedAnimation(
                parent: _entryController,
                curve: Curves.easeOut,
              ),
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.05),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: _entryController,
                    curve: Curves.easeOut,
                  ),
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Column(
                    children: [
                      const SizedBox(height: 42),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(24),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white30),
                        ),
                        child: const Icon(
                          Icons.waves,
                          size: 42,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'FLOOTE',
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Sign in to access real-time flood data',
                        style: TextStyle(fontSize: 15, color: Colors.white70),
                      ),
                      const SizedBox(height: 24),
                      if (_showVerificationPanel) ...[
                        _buildEmailVerificationPanel(),
                        const SizedBox(height: 16),
                      ],
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(232),
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black26,
                              blurRadius: 16,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            Container(
                              height: 50,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEFF4FD),
                                borderRadius: BorderRadius.circular(25),
                              ),
                              child: Row(
                                children: [
                                  Expanded(child: _buildActiveTab('Login')),
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => Navigator.pushReplacement(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              const RegisterPage(),
                                        ),
                                      ),
                                      child: const Center(
                                        child: Text(
                                          'Register',
                                          style: TextStyle(
                                            color: Colors.grey,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            _buildInputField(
                              label: 'Username or Email',
                              hint: 'username or your.email@example.com',
                              controller: _identifierController,
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Password',
                              hint: '••••••••',
                              isPassword: true,
                              controller: _passwordController,
                              passwordObscured: _obscurePassword,
                              onTogglePasswordVisibility: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 54,
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : _handleLogin,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1A60FF),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
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
                                        'Sign In',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) =>
                                      const ForgotPasswordPage(),
                                ),
                              ),
                              child: const Text(
                                'Forgot password?',
                                style: TextStyle(
                                  color: Color(0xFF1A60FF),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlow(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _buildActiveTab(String label) {
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(21),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
      ),
      child: Center(
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildInputField({
    required String label,
    required String hint,
    required TextEditingController controller,
    bool isPassword = false,
    bool? passwordObscured,
    VoidCallback? onTogglePasswordVisibility,
  }) {
    final showPasswordToggle =
        isPassword && onTogglePasswordVisibility != null;
    final effectiveObscure = isPassword ? (passwordObscured ?? true) : false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: Color(0xFF12305E),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: effectiveObscure,
          keyboardType:
              isPassword ? TextInputType.visiblePassword : TextInputType.text,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.grey[400]),
            filled: true,
            fillColor: const Color(0xFFF4F8FF),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
            suffixIcon: showPasswordToggle
                ? IconButton(
                    tooltip: effectiveObscure ? 'Show password' : 'Hide password',
                    onPressed: onTogglePasswordVisibility,
                    icon: Icon(
                      effectiveObscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: const Color(0xFF12305E),
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}