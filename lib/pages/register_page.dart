import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/auth_login.dart';
import '../utils/password_policy.dart';
import '../utils/philippine_mobile_input_formatter.dart';
import '../utils/philippine_phone.dart';
import 'login_page.dart';
import '../widgets/password_confirm_match_panel.dart';
import '../widgets/password_requirements_panel.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

enum _AvailabilityStatus { idle, checking, available, taken, error }

class _RegisterPageState extends State<RegisterPage>
    with TickerProviderStateMixin {
  static const int _minRegistrationAgeYears = 13;
  static const int _maxRegistrationAgeYears = 120;
  static final RegExp _emailRegex = RegExp(
    r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$',
  );

  final _givenNameController = TextEditingController();
  final _middleNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _dobController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  String? _selectedGender;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _confirmFocusNode = FocusNode();
  Timer? _usernameDebounce;
  Timer? _phoneDebounce;
  Timer? _emailDebounce;
  _AvailabilityStatus _usernameAvailability = _AvailabilityStatus.idle;
  _AvailabilityStatus _phoneAvailability = _AvailabilityStatus.idle;
  _AvailabilityStatus _emailAvailability = _AvailabilityStatus.idle;
  int _usernameCheckSeq = 0;
  int _phoneCheckSeq = 0;
  int _emailCheckSeq = 0;
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
    for (final c in _allControllers) {
      c.addListener(_onFormChanged);
    }
    _usernameController.addListener(_onUsernameChanged);
    _phoneController.addListener(_onPhoneChanged);
    _emailController.addListener(_onEmailChanged);
  }

  @override
  void dispose() {
    _usernameDebounce?.cancel();
    _phoneDebounce?.cancel();
    _emailDebounce?.cancel();
    _usernameController.removeListener(_onUsernameChanged);
    _phoneController.removeListener(_onPhoneChanged);
    _emailController.removeListener(_onEmailChanged);
    for (final c in _allControllers) {
      c.removeListener(_onFormChanged);
    }
    _givenNameController.dispose();
    _middleNameController.dispose();
    _lastNameController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _dobController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _bgController.dispose();
    _entryController.dispose();
    super.dispose();
  }

  String _formatDob(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    final yyyy = date.year.toString();
    return '$mm/$dd/$yyyy';
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final oldestAllowed = DateTime(
      now.year - _maxRegistrationAgeYears,
      now.month,
      now.day,
    );
    final youngestAllowed = DateTime(
      now.year - _minRegistrationAgeYears,
      now.month,
      now.day,
    );
    final initial = DateTime(now.year - 18, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(oldestAllowed) ||
              initial.isAfter(youngestAllowed)
          ? youngestAllowed
          : initial,
      firstDate: oldestAllowed,
      lastDate: youngestAllowed,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dobController.text = _formatDob(picked);
    });
  }

  bool _isDobValid(String dob) {
    final raw = dob.trim();
    final m = RegExp(r'^(\d{2})\/(\d{2})\/(\d{4})$').firstMatch(raw);
    if (m == null) return false;
    final month = int.tryParse(m.group(1)!);
    final day = int.tryParse(m.group(2)!);
    final year = int.tryParse(m.group(3)!);
    if (month == null || day == null || year == null) return false;
    final parsed = DateTime.tryParse(
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}',
    );
    if (parsed == null) return false;
    if (parsed.month != month || parsed.day != day || parsed.year != year) {
      return false;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final oldestAllowed = DateTime(
      today.year - _maxRegistrationAgeYears,
      today.month,
      today.day,
    );
    final youngestAllowed = DateTime(
      today.year - _minRegistrationAgeYears,
      today.month,
      today.day,
    );
    return !parsed.isBefore(oldestAllowed) && !parsed.isAfter(youngestAllowed);
  }

  List<TextEditingController> get _allControllers => [
        _givenNameController,
        _middleNameController,
        _lastNameController,
        _usernameController,
        _emailController,
        _phoneController,
        _dobController,
        _passwordController,
        _confirmPasswordController,
      ];

  void _onFormChanged() {
    if (mounted) setState(() {});
  }

  void _onUsernameChanged() {
    final username = normalizeAuthIdentifier(_usernameController.text);
    _usernameDebounce?.cancel();
    final reqId = ++_usernameCheckSeq;
    if (username.isEmpty) {
      setState(() => _usernameAvailability = _AvailabilityStatus.idle);
      return;
    }
    setState(() => _usernameAvailability = _AvailabilityStatus.checking);
    _usernameDebounce = Timer(const Duration(milliseconds: 450), () {
      _checkAvailability(username: username, requestId: reqId);
    });
  }

  void _onPhoneChanged() {
    final phone = normalizePhilippineMobile(_phoneController.text);
    _phoneDebounce?.cancel();
    final reqId = ++_phoneCheckSeq;
    if (phone == null) {
      setState(() => _phoneAvailability = _AvailabilityStatus.idle);
      return;
    }
    setState(() => _phoneAvailability = _AvailabilityStatus.checking);
    _phoneDebounce = Timer(const Duration(milliseconds: 450), () {
      _checkAvailability(phone: phone, requestId: reqId);
    });
  }

  void _onEmailChanged() {
    final email = normalizeAuthIdentifier(_emailController.text);
    _emailDebounce?.cancel();
    final reqId = ++_emailCheckSeq;
    if (!_isEmailValid(email)) {
      setState(() => _emailAvailability = _AvailabilityStatus.idle);
      return;
    }
    setState(() => _emailAvailability = _AvailabilityStatus.checking);
    _emailDebounce = Timer(const Duration(milliseconds: 450), () {
      _checkAvailability(email: email, requestId: reqId);
    });
  }

  Future<void> _checkAvailability({
    String? username,
    String? phone,
    String? email,
    required int requestId,
  }) async {
    try {
      final supabase = Supabase.instance.client;
      final dynamic raw = await supabase.rpc(
        'check_registration_availability',
        params: {
          'p_username': username,
          'p_phone_number': phone,
          'p_email': email,
        },
      );
      if (!mounted) return;

      bool usernameTaken = false;
      bool phoneTaken = false;
      bool emailTaken = false;
      if (raw is Map) {
        usernameTaken = raw['username_taken'] == true;
        phoneTaken = raw['phone_taken'] == true;
        emailTaken = raw['email_taken'] == true;
      } else if (raw is List && raw.isNotEmpty && raw.first is Map) {
        final first = raw.first as Map;
        usernameTaken = first['username_taken'] == true;
        phoneTaken = first['phone_taken'] == true;
        emailTaken = first['email_taken'] == true;
      }

      setState(() {
        if (username != null && requestId == _usernameCheckSeq) {
          _usernameAvailability = usernameTaken
              ? _AvailabilityStatus.taken
              : _AvailabilityStatus.available;
        }
        if (phone != null && requestId == _phoneCheckSeq) {
          _phoneAvailability = phoneTaken
              ? _AvailabilityStatus.taken
              : _AvailabilityStatus.available;
        }
        if (email != null && requestId == _emailCheckSeq) {
          _emailAvailability = emailTaken
              ? _AvailabilityStatus.taken
              : _AvailabilityStatus.available;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (username != null && requestId == _usernameCheckSeq) {
          _usernameAvailability = _AvailabilityStatus.error;
        }
        if (phone != null && requestId == _phoneCheckSeq) {
          _phoneAvailability = _AvailabilityStatus.error;
        }
        if (email != null && requestId == _emailCheckSeq) {
          _emailAvailability = _AvailabilityStatus.error;
        }
      });
    }
  }

  bool _isEmailValid(String email) => _emailRegex.hasMatch(email);

  bool get _isRegistrationFormValid {
    final givenName = _givenNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final username = normalizeAuthIdentifier(_usernameController.text);
    final email = normalizeAuthIdentifier(_emailController.text);
    final dob = _dobController.text.trim();
    final password = _passwordController.text.trim();
    final confirm = _confirmPasswordController.text.trim();

    if (givenName.isEmpty ||
        lastName.isEmpty ||
        username.isEmpty ||
        email.isEmpty ||
        dob.isEmpty ||
        password.isEmpty ||
        confirm.isEmpty ||
        _selectedGender == null) {
      return false;
    }
    if (!_isEmailValid(email)) return false;
    if (!_isDobValid(dob)) return false;
    if (normalizePhilippineMobile(_phoneController.text) == null) return false;
    if (PasswordPolicy.validate(password) != null) return false;
    if (password != confirm) return false;
    if (_usernameAvailability != _AvailabilityStatus.available) return false;
    if (_phoneAvailability != _AvailabilityStatus.available) return false;
    if (_emailAvailability != _AvailabilityStatus.available) return false;
    return true;
  }

  Future<void> _handleRegistration() async {
    // Basic Validation
    if (_givenNameController.text.trim().isEmpty ||
        _lastNameController.text.trim().isEmpty ||
        _usernameController.text.trim().isEmpty ||
        _emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty ||
        _confirmPasswordController.text.isEmpty ||
        _phoneController.text.trim().isEmpty ||
        _dobController.text.trim().isEmpty ||
        _selectedGender == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields')),
      );
      return;
    }
    if (!_isDobValid(_dobController.text)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter a valid date of birth in MM/DD/YYYY (age 13 to 120).',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final password = _passwordController.text.trim();
    final passwordPolicyError = PasswordPolicy.validate(password);
    if (passwordPolicyError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(passwordPolicyError),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    if (password != _confirmPasswordController.text.trim()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Passwords do not match.'),
          backgroundColor: Colors.redAccent,
        ),
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
      final givenName = _givenNameController.text.trim();
      final middleName = _middleNameController.text.trim();
      final lastName = _lastNameController.text.trim();
      final username = normalizeAuthIdentifier(_usernameController.text);
      final email = normalizeAuthIdentifier(_emailController.text);
      final dob = _dobController.text.trim();
      final sex = _selectedGender!;
      final fullName = middleName.isEmpty
          ? '$givenName $lastName'
          : '$givenName $middleName $lastName';

      if (!_isEmailValid(email)) {
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
        password: password,
        emailRedirectTo: emailConfirmRedirectUrl(),
        data: {
          'username': username,
          'phone_number': phoneNormalized,
          'given_name': givenName,
          'middle_name': middleName,
          'last_name': lastName,
          'full_name': fullName,
          'date_of_birth': dob,
          'sex': sex,
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

      // Profiles are created server-side by the auth.users trigger (handle_new_user).
      // Avoid client-side upsert here because it may fail under RLS when email
      // confirmation is required (session can be null), even though sign-up succeeded.

      if (!mounted) return;

      final confirmed = res.user!.emailConfirmedAt != null &&
          res.user!.emailConfirmedAt!.trim().isNotEmpty;
      final needsEmailVerification = !confirmed;

      ScaffoldMessenger.of(context).clearSnackBars();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => needsEmailVerification
              ? LoginPage(
                  showEmailVerificationRequired: true,
                  registeredEmailForResend: email,
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
                              label: 'Given Name',
                              hint: 'your.givenname',
                              controller: _givenNameController,
                              keyboardType: TextInputType.name,
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Middle Name',
                              hint: '(optional)',
                              controller: _middleNameController,
                              keyboardType: TextInputType.name,
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Last Name',
                              hint: 'your.lastname',
                              controller: _lastNameController,
                              keyboardType: TextInputType.name,
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Username',
                              hint: 'your.username',
                              controller: _usernameController,
                              keyboardType: TextInputType.text,
                            ),
                            _buildAvailabilityMessage(
                              status: _usernameAvailability,
                              idleMessage: '',
                              checkingMessage: 'Checking username...',
                              takenMessage: 'Username already taken',
                              availableMessage: 'Username is available',
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Email',
                              hint: 'your.email@example.com',
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                            ),
                            _buildAvailabilityMessage(
                              status: _emailAvailability,
                              idleMessage: '',
                              checkingMessage: 'Checking email...',
                              takenMessage: 'Email already registered',
                              availableMessage: 'Email is available',
                            ),
                            const SizedBox(height: 16),
                            _buildPhilippinePhoneField(),
                            _buildAvailabilityMessage(
                              status: _phoneAvailability,
                              idleMessage: '',
                              checkingMessage: 'Checking phone number...',
                              takenMessage: 'Phone already registered',
                              availableMessage: 'Phone number is available',
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'DOB (MM/DD/YYYY)',
                              hint: 'MM/DD/YYYY',
                              controller: _dobController,
                              keyboardType: TextInputType.datetime,
                              readOnly: true,
                              onTap: _pickDob,
                            ),
                            const SizedBox(height: 16),
                            _buildGenderDropdown(),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Password',
                              hint: '••••••••',
                              isPassword: true,
                              controller: _passwordController,
                              focusNode: _passwordFocusNode,
                              passwordObscured: _obscurePassword,
                              onTogglePasswordVisibility: () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                            ),
                            const SizedBox(height: 12),
                            PasswordRequirementsPanel(
                              controller: _passwordController,
                              focusNode: _passwordFocusNode,
                              dense: true,
                            ),
                            const SizedBox(height: 16),
                            _buildInputField(
                              label: 'Confirm Password',
                              hint: '••••••••',
                              isPassword: true,
                              controller: _confirmPasswordController,
                              focusNode: _confirmFocusNode,
                              passwordObscured: _obscureConfirmPassword,
                              onTogglePasswordVisibility: () => setState(
                                () => _obscureConfirmPassword =
                                    !_obscureConfirmPassword,
                              ),
                            ),
                            const SizedBox(height: 12),
                            PasswordConfirmMatchPanel(
                              passwordController: _passwordController,
                              confirmController: _confirmPasswordController,
                              confirmFocusNode: _confirmFocusNode,
                              dense: true,
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 54,
                              child: ElevatedButton(
                                onPressed: _isLoading
                                    || !_isRegistrationFormValid
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

  Widget _buildPhilippinePhoneField() {
    const fill = Color(0xFFF4F8FF);
    const labelColor = Color(0xFF12305E);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Phone Number',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: labelColor,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '🇵🇭',
                      style: TextStyle(fontSize: 20),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '+63',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: labelColor,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 1,
                height: 28,
                color: labelColor.withValues(alpha: 0.15),
              ),
              Expanded(
                child: TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    PhilippineNationalMobileInputFormatter(),
                  ],
                  decoration: const InputDecoration(
                    hintText: '9XX XXX XXXX',
                    border: InputBorder.none,
                    isDense: true,
                    filled: false,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    hintStyle: TextStyle(color: Color(0x99000000)),
                  ),
                  style: const TextStyle(
                    fontSize: 16,
                    color: Color(0xFF12305E),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAvailabilityMessage({
    required _AvailabilityStatus status,
    required String idleMessage,
    required String checkingMessage,
    required String takenMessage,
    required String availableMessage,
  }) {
    String text;
    Color color;
    switch (status) {
      case _AvailabilityStatus.idle:
        text = idleMessage;
        color = Colors.transparent;
        break;
      case _AvailabilityStatus.checking:
        text = checkingMessage;
        color = Colors.grey.shade600;
        break;
      case _AvailabilityStatus.taken:
        text = takenMessage;
        color = Colors.redAccent;
        break;
      case _AvailabilityStatus.available:
        text = availableMessage;
        color = Colors.green.shade700;
        break;
      case _AvailabilityStatus.error:
        text = 'Cannot check availability right now.';
        color = Colors.redAccent;
        break;
    }
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildInputField({
    required String label,
    required String hint,
    required TextEditingController controller,
    FocusNode? focusNode,
    bool isPassword = false,
    String? helperText,
    TextInputType keyboardType = TextInputType.text,
    bool readOnly = false,
    VoidCallback? onTap,
    bool? passwordObscured,
    VoidCallback? onTogglePasswordVisibility,
  }) {
    final bool showPasswordToggle =
        isPassword && onTogglePasswordVisibility != null;
    final bool effectiveObscure =
        isPassword ? (passwordObscured ?? true) : false;

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
          focusNode: focusNode,
          obscureText: effectiveObscure,
          keyboardType: isPassword ? TextInputType.visiblePassword : keyboardType,
          readOnly: readOnly,
          onTap: onTap,
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

  Widget _buildGenderDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Gender',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: Color(0xFF12305E),
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: _selectedGender,
          items: const [
            DropdownMenuItem(value: 'Male', child: Text('Male')),
            DropdownMenuItem(value: 'Female', child: Text('Female')),
            DropdownMenuItem(
              value: 'Prefer not to say',
              child: Text('Prefer not to say'),
            ),
          ],
          onChanged: (value) => setState(() => _selectedGender = value),
          decoration: InputDecoration(
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
          hint: const Text('Select gender'),
        ),
      ],
    );
  }
}
