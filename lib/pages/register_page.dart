import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:postgrest/postgrest.dart' show PostgrestException;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/auth_login.dart';
import '../utils/philippine_phone.dart';
import 'login_page.dart';
import 'location_permission_page.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage>
    with TickerProviderStateMixin {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  late final AnimationController _bgController;
  late final AnimationController _entryController;

  @override
  void initState() {
    super.initState();
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _bgController.dispose();
    _entryController.dispose();
    super.dispose();
  }

  Future<void> _handleRegistration() async {
    // Basic Validation
    if (_usernameController.text.isEmpty ||
        _emailController.text.isEmpty ||
        _passwordController.text.isEmpty ||
        _phoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields')),
      );
      return;
    }

    final phoneNormalized = normalizePhilippineMobile(_phoneController.text);
    if (phoneNormalized == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(kInvalidPhilippineMobile),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }

    setState(() => _isLoading = true);

    try {
      final supabase = Supabase.instance.client;
      final username = normalizeAuthIdentifier(_usernameController.text);
      final email = normalizeAuthIdentifier(_emailController.text);

      if (!email.contains('@')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(kRegistrationEmailInvalid),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }

      // No pre-check of username in profiles: it can leak whether a username
      // exists and often fails under RLS. Uniqueness is enforced in the database.

      final AuthResponse res = await supabase.auth.signUp(
        email: email,
        password: _passwordController.text.trim(),
        data: {
          'username': username,
          'phone_number': phoneNormalized,
        },
      );

      if (res.user == null) {
        if (kDebugMode) {
          debugPrint('Register: signUp returned no user.');
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(kRegistrationFailed),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }

      final profileRow = <String, dynamic>{
        'id': res.user!.id,
        'username': username,
        'email': email,
        'role': 'user',
        'phone_number': phoneNormalized,
      };

      try {
        await supabase.from('profiles').upsert(
          profileRow,
          onConflict: 'id',
        );
      } on PostgrestException catch (e, st) {
        if (kDebugMode) {
          debugPrint('profiles upsert failed: $e\n$st');
        }
        if (res.session != null) {
          await supabase.auth.signOut();
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(registrationProfileErrorMessage(e)),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      if (!mounted) return;

      final hasSession = res.session != null;
      ScaffoldMessenger.of(context).clearSnackBars();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => hasSession
              ? const LocationPermissionPage(
                  initialBannerText: kRegistrationSuccess,
                )
              : const LoginPage(
                  initialBannerText: kRegistrationCreatedUseSignIn,
                  initialBannerSuccess: true,
                ),
        ),
      );
    } on AuthException catch (e) {
      if (kDebugMode) {
        debugPrint(
          'Register AuthException: ${e.message} code=${e.code} status=${e.statusCode}',
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(registrationAuthErrorMessage(e)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('Register error: $e\n$st');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(kRegistrationFailed),
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
                  Color(0xFF0C2344),
                  Color(0xFF174073),
                  Color(0xFF1A60FF),
                ],
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _bgController,
            builder: (context, child) => Stack(
              children: [
                Positioned(
                  top: -120 + (_bgController.value * 35),
                  left: -80,
                  child: _buildGlow(260, Colors.cyanAccent.withAlpha(40)),
                ),
                Positioned(
                  bottom: -130,
                  right: -80 + (_bgController.value * 28),
                  child: _buildGlow(300, Colors.lightBlueAccent.withAlpha(34)),
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
                position:
                    Tween<Offset>(
                      begin: const Offset(0, 0.06),
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
                        'Create your account for safer travel',
                        style: TextStyle(fontSize: 15, color: Colors.white70),
                      ),
                      const SizedBox(height: 24),
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
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => Navigator.pushReplacement(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              const LoginPage(),
                                        ),
                                      ),
                                      child: const Center(
                                        child: Text(
                                          'Login',
                                          style: TextStyle(
                                            color: Colors.grey,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(child: _buildActiveTab('Register')),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            _buildInputField(
                              label: 'Username',
                              hint: 'your.username',
                              controller: _usernameController,
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Email',
                              hint: 'your.email@example.com',
                              controller: _emailController,
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Phone Number *',
                              hint: '09XX XXX XXXX or +639XX XXX XXXX',
                              controller: _phoneController,
                              helperText: 'Philippine mobile number (required)',
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Password',
                              hint: '••••••••',
                              isPassword: true,
                              controller: _passwordController,
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 54,
                              child: ElevatedButton(
                                onPressed: _isLoading
                                    ? null
                                    : _handleRegistration,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF1A60FF),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
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
                                        'Create Account',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.bold,
                                        ),
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
    String? helperText,
  }) {
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
          obscureText: isPassword,
          keyboardType:
              isPassword ? TextInputType.visiblePassword : TextInputType.phone,
          decoration: InputDecoration(
            hintText: hint,
            helperText: helperText,
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
          ),
        ),
      ],
    );
  }
}
