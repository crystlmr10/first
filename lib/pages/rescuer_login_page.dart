import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/auth_login.dart';
import 'rescuer_home_page.dart';

class RescuerLoginPage extends StatefulWidget {
  const RescuerLoginPage({super.key});

  @override
  State<RescuerLoginPage> createState() => _RescuerLoginPageState();
}

class _RescuerLoginPageState extends State<RescuerLoginPage> {
  final TextEditingController _rescuerIdController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocusNode = FocusNode();
  bool _obscurePassword = true;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _rescuerIdController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handlePortalAccess() async {
    final rescuerId = _rescuerIdController.text.trim();
    final password = _passwordController.text.trim();

    if (rescuerId.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your Rescuer ID and password'),
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final client = Supabase.instance.client;

      final resolvedEmail = await _resolveRescuerEmail(client, rescuerId);

      if (resolvedEmail == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(kInvalidLoginCredentials),
            backgroundColor: Colors.redAccent,
          ),
        );
        return;
      }

      final auth = await client.auth.signInWithPassword(
        email: resolvedEmail,
        password: password,
      );

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
      final isRescuer = role == 'rescuer';

      if (!isRescuer) {
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

      // After successful rescuer login, default to on-duty in DB so they don't stay off-duty
      // from a previous session. HomePage then loads this via _loadRescuerDutyFromProfile.
      try {
        try {
          await client.auth.refreshSession();
        } catch (e) {
          debugPrint('rescuer login on-duty: refreshSession skipped: $e');
        }
        await client.rpc(
          'set_rescuer_on_duty',
          params: {'p_on_duty': true},
        );
      } catch (e, st) {
        debugPrint('rescuer login set on-duty: $e\n$st');
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const RescuerHomePage()),
      );
    } on AuthException catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(kInvalidLoginCredentials),
          backgroundColor: Colors.redAccent,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(kInvalidLoginCredentials),
          backgroundColor: Colors.redAccent,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<String?> _resolveRescuerEmail(
    SupabaseClient client,
    String rescuerIdOrEmail,
  ) async {
    final normalized = normalizeAuthIdentifier(rescuerIdOrEmail);

    if (normalized.contains('@')) {
      return normalized;
    }

    try {
      final byUsername = await client
          .from('profiles')
          .select('email')
          .eq('username', normalized)
          .eq('role', 'rescuer')
          .maybeSingle();
      final emailFromUsername =
          byUsername?['email']?.toString().trim().toLowerCase();
      if (emailFromUsername != null && emailFromUsername.isNotEmpty) {
        return emailFromUsername;
      }

      // Legacy: local-part prefix before @ (lowercase [profiles.email]).
      final row = await client
          .from('profiles')
          .select('email')
          .eq('role', 'rescuer')
          .like('email', '$normalized@%')
          .limit(1)
          .maybeSingle();

      final legacy = row?['email']?.toString().trim().toLowerCase();
      if (legacy == null || legacy.isEmpty) return null;
      return legacy;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B263B), // Dark Navy Theme
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                30,
                20,
                30,
                MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 40),
                child: IntrinsicHeight(
                  child: Column(
                    children: [
                      // Rescuer Shield Icon
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF1A60FF), width: 1),
                        ),
                        child: const Icon(
                          Icons.shield_outlined,
                          size: 60,
                          color: Color(0xFF1A60FF),
                        ),
                      ),
                      const SizedBox(height: 30),
                      const Text(
                        'Rescuer Access',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const Text(
                        'Emergency Response Portal',
                        style: TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                      const SizedBox(height: 30),
                      _buildRescuerInput(
                        icon: Icons.person_outline,
                        label: 'Rescuer ID or Email',
                        controller: _rescuerIdController,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _passwordFocusNode.requestFocus(),
                      ),
                      const SizedBox(height: 20),
                      _buildRescuerInput(
                        icon: Icons.lock_outline,
                        label: 'Password',
                        controller: _passwordController,
                        isPassword: true,
                        focusNode: _passwordFocusNode,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _handlePortalAccess(),
                        passwordObscured: _obscurePassword,
                        onTogglePasswordVisibility: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                      const SizedBox(height: 30),
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _isSubmitting ? null : _handlePortalAccess,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1A60FF),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isSubmitting
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Access Portal',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Restriction Notice
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: const Text(
                          'This portal is restricted to authorized emergency responders only. Unauthorized access is prohibited.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                      ),
                      const Spacer(),
                      const Text(
                        'Cebu City Emergency Response',
                        style: TextStyle(color: Colors.white24, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildRescuerInput({
    required IconData icon,
    required String label,
    required TextEditingController controller,
    bool isPassword = false,
    FocusNode? focusNode,
    TextInputAction? textInputAction,
    ValueChanged<String>? onSubmitted,
    bool? passwordObscured,
    VoidCallback? onTogglePasswordVisibility,
  }) {
    final showToggle = isPassword && onTogglePasswordVisibility != null;
    final effectiveObscure = isPassword ? (passwordObscured ?? true) : false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          focusNode: focusNode,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          obscureText: effectiveObscure,
          keyboardType:
              isPassword ? TextInputType.visiblePassword : TextInputType.text,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: Colors.white38),
            hintText: 'Enter your ${label.toLowerCase()}',
            hintStyle: const TextStyle(color: Colors.white24),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white10),
            ),
            suffixIcon: showToggle
                ? IconButton(
                    tooltip:
                        effectiveObscure ? 'Show password' : 'Hide password',
                    onPressed: onTogglePasswordVisibility,
                    icon: Icon(
                      effectiveObscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: Colors.white70,
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}
