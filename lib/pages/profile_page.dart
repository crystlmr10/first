import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/philippine_phone.dart';

/// Profile screen: loads/saves [public.profiles] (see `supabase/sql/profiles_table.sql`).
class ProfilePage extends StatefulWidget {
  const ProfilePage({
    super.key,
    required this.isRescuerAccount,
    this.embeddedInShell = false,
  });

  final bool isRescuerAccount;
  final bool embeddedInShell;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const Color _cream = Color(0xFFF8F4EC);
  static const Color _headerBlue = Color(0xFFC8DDF5);
  static const Color _avatarFill = Color(0xFFE8F0FA);
  static const Color _darkBlue = Color(0xFF0D2B5C);
  static const Color _labelBlue = Color(0xFF2563EB);
  static const Color _cardBorder = Color(0xFFD9D9D9);

  bool _editing = false;
  bool _passwordExpanded = false;
  bool _saving = false;
  bool _loading = true;
  String? _loadError;
  String? _accountEmail;
  File? _avatarFile;

  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _phoneController = TextEditingController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProfile());
  }

  String? _firstNonEmpty(List<String?> values) {
    for (final v in values) {
      final t = v?.trim();
      if (t != null && t.isNotEmpty) return t;
    }
    return null;
  }

  Future<void> _loadProfile({bool showFullScreenLoader = true}) async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    if (showFullScreenLoader && mounted) {
      setState(() {
        _loadError = null;
        _loading = true;
      });
    }

    try {
      final row = await client
          .from('profiles')
          .select('username, phone_number, email')
          .eq('id', user.id)
          .maybeSingle();

      final meta = user.userMetadata ?? {};
      final username = _firstNonEmpty([
        row?['username'] as String?,
        meta['username'] as String?,
      ]);
      final phoneRaw = _firstNonEmpty([
        row?['phone_number'] as String?,
        meta['phone_number'] as String?,
      ]);

      _accountEmail =
          _firstNonEmpty([row?['email'] as String?, user.email]) ?? user.email;

      if (!mounted) return;
      setState(() {
        _nameController.text = username ?? '';
        _phoneController.text = (phoneRaw != null && phoneRaw.isNotEmpty)
            ? _formatPhoneDisplay(phoneRaw)
            : '';
        if (showFullScreenLoader) {
          _loadError = null;
          _loading = false;
        }
      });
    } catch (e) {
      if (!mounted) return;
      if (showFullScreenLoader) {
        setState(() {
          _loadError = e.toString();
          _loading = false;
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reload profile: $e')),
        );
      }
    }
  }

  Future<void> _reloadControllersFromSession() =>
      _loadProfile(showFullScreenLoader: false);

  String _formatPhoneDisplay(String normalizedDigits) {
    final d = normalizedDigits.replaceAll(RegExp(r'\D'), '');
    if (d.length >= 12 && d.startsWith('63')) {
      final rest = d.substring(2);
      if (rest.length >= 10) {
        return '+63 ${rest.substring(0, 3)} ${rest.substring(3, 6)} ${rest.substring(6, 10)}';
      }
    }
    return normalizedDigits;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  String get _initials {
    final name = _nameController.text.trim();
    if (name.isNotEmpty) {
      final parts = name.split(RegExp(r'\s+'));
      if (parts.length == 1) {
        final s = parts.first;
        return s.length >= 2 ? s.substring(0, 2).toUpperCase() : s.toUpperCase();
      }
      return (parts.first[0] + parts.last[0]).toUpperCase();
    }
    final em = _accountEmail;
    if (em != null && em.isNotEmpty) {
      return em[0].toUpperCase();
    }
    return '?';
  }

  String get _headerTitleLine {
    final n = _nameController.text.trim();
    if (n.isNotEmpty) return n;
    final em = _accountEmail;
    if (em != null && em.isNotEmpty) return em;
    return '—';
  }

  bool get _headerUsesEmailFallback =>
      _nameController.text.trim().isEmpty &&
      (_accountEmail != null && _accountEmail!.isNotEmpty);

  String get _roleLabel => widget.isRescuerAccount ? 'RESCUER' : 'USER';

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      imageQuality: 85,
    );
    if (x == null || !mounted) return;
    setState(() => _avatarFile = File(x.path));
  }

  Future<void> _save() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) return;

    final name = _nameController.text.trim();
    final rawPhone = _phoneController.text.trim();
    String? phoneNormalized;
    if (rawPhone.isEmpty) {
      phoneNormalized = null;
    } else {
      phoneNormalized = normalizePhilippineMobile(rawPhone);
      if (phoneNormalized == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Enter a valid PH mobile number, or clear the field.',
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final email = user.email;
      final existing = await client
          .from('profiles')
          .select('role')
          .eq('id', user.id)
          .maybeSingle();
      final role = (existing?['role'] as String?)?.trim();
      final resolvedRole = (role != null && role.isNotEmpty)
          ? role
          : (widget.isRescuerAccount ? 'rescuer' : 'user');

      await client.from('profiles').upsert(
        <String, dynamic>{
          'id': user.id,
          if (email != null) 'email': email,
          'username': name.isEmpty ? null : name,
          'phone_number': phoneNormalized,
          'role': resolvedRole,
        },
        onConflict: 'id',
      );

      await client.auth.updateUser(
        UserAttributes(
          data: <String, dynamic>{
            if (name.isNotEmpty) 'username': name,
            if (phoneNormalized != null) 'phone_number': phoneNormalized,
          },
        ),
      );

      if (mounted) {
        setState(() {
          _editing = false;
          _saving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out'),
        content: const Text('Sign out of Floote on this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await Supabase.instance.client.auth.signOut();
  }

  /// Nested [Scaffold] inside [HomePage]'s body can get zero height / show the
  /// parent dark background unless we expand and mark this scaffold non-primary.
  Widget _wrapForHomeShell(Widget child) {
    if (!widget.embeddedInShell) return child;
    return SizedBox.expand(child: child);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _wrapForHomeShell(
        Scaffold(
        primary: !widget.embeddedInShell,
        backgroundColor: _cream,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: _darkBlue,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          leading: widget.embeddedInShell
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  onPressed: () => Navigator.maybePop(context),
                ),
          title: const Text(
            'Profile',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 20,
              color: _darkBlue,
            ),
          ),
          centerTitle: true,
          automaticallyImplyLeading: !widget.embeddedInShell,
        ),
        body: const Center(child: CircularProgressIndicator(color: _labelBlue)),
      ),
    );
    }

    if (_loadError != null) {
      return _wrapForHomeShell(
        Scaffold(
        primary: !widget.embeddedInShell,
        backgroundColor: _cream,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: _darkBlue,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          leading: widget.embeddedInShell
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  onPressed: () => Navigator.maybePop(context),
                ),
          title: const Text(
            'Profile',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 20,
              color: _darkBlue,
            ),
          ),
          centerTitle: true,
          automaticallyImplyLeading: !widget.embeddedInShell,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Could not load profile.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.blueGrey.shade700, fontSize: 13),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loadProfile,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    }

    return _wrapForHomeShell(
      Scaffold(
      primary: !widget.embeddedInShell,
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _darkBlue,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: widget.embeddedInShell
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
                onPressed: () => Navigator.maybePop(context),
              ),
        title: const Text(
          'Profile',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 20,
            color: _darkBlue,
          ),
        ),
        centerTitle: true,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: Color(0xFFE5E5E5)),
        ),
        automaticallyImplyLeading: !widget.embeddedInShell,
        actions: [
          if (_editing)
            TextButton(
              onPressed: _saving
                  ? null
                  : () => setState(() {
                        _reloadControllersFromSession();
                        _editing = false;
                        _passwordExpanded = false;
                      }),
              child: const Text(
                'Cancel',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            TextButton(
              onPressed: () => setState(() => _editing = true),
              child: const Text(
                'Edit',
                style: TextStyle(
                  color: _labelBlue,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPersonalCard(),
                  const SizedBox(height: 14),
                  _buildAccountCard(),
                  if (_editing) ...[
                    const SizedBox(height: 20),
                    _buildSaveButton(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 24),
      decoration: const BoxDecoration(
        color: _headerBlue,
        border: Border(
          bottom: BorderSide(color: Color(0xFFB8CCE0), width: 1),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withAlpha(20),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: CircleAvatar(
                  radius: 56,
                  backgroundColor: _avatarFill,
                  backgroundImage:
                      _avatarFile != null ? FileImage(_avatarFile!) : null,
                  child: _avatarFile == null
                      ? Text(
                          _initials,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: _darkBlue,
                          ),
                        )
                      : null,
                ),
              ),
              if (_editing)
                Positioned(
                  right: -4,
                  bottom: 0,
                  child: Material(
                    color: _darkBlue,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _pickAvatar,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(
                          Icons.photo_camera_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            _headerTitleLine,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: _headerUsesEmailFallback ? 17 : 22,
              fontWeight:
                  _headerUsesEmailFallback ? FontWeight.w600 : FontWeight.w800,
              color: _headerUsesEmailFallback
                  ? Colors.blueGrey.shade800
                  : _darkBlue,
            ),
          ),
          if (_headerUsesEmailFallback) ...[
            const SizedBox(height: 6),
            Text(
              'Add your display name below',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Colors.blueGrey.shade600,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: _darkBlue,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _roleLabel,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 12,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPersonalCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cardBorder),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PERSONAL INFORMATION',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: _labelBlue,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 14),
          if (_editing) ...[
            _labeledField(
              label: 'Full name',
              child: TextField(
                controller: _nameController,
                onChanged: (_) => setState(() {}),
                decoration: _inputDecoration(),
              ),
            ),
            const SizedBox(height: 12),
            _labeledField(
              label: 'Contact number',
              child: TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: _inputDecoration(),
              ),
            ),
          ] else ...[
            _readRow('Full name', _nameController.text),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, color: Color(0xFFE8E8E8)),
            ),
            _readRow('Contact number', _phoneController.text),
          ],
        ],
      ),
    );
  }

  InputDecoration _inputDecoration() {
    return InputDecoration(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      filled: true,
      fillColor: const Color(0xFFFAFAFA),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _cardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _labelBlue, width: 1.5),
      ),
    );
  }

  Widget _labeledField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Colors.blueGrey.shade700,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _readRow(String label, String value) {
    final empty = value.trim().isEmpty;
    final display = empty ? 'Not set' : value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: Colors.blueGrey.shade700,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          display,
          style: TextStyle(
            fontSize: 16,
            color: empty ? Colors.blueGrey.shade500 : const Color(0xFF1A1A1A),
            fontWeight: FontWeight.w500,
            fontStyle: empty ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildAccountCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cardBorder),
      ),
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'ACCOUNT SETTINGS',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: _labelBlue,
                letterSpacing: 0.6,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_editing && _passwordExpanded) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Use the password reset email from login, or contact support.',
                style: TextStyle(color: Colors.blueGrey.shade600, fontSize: 13),
              ),
            ),
            const SizedBox(height: 8),
          ],
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                setState(() {
                  _passwordExpanded = !_passwordExpanded;
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline_rounded,
                        color: _labelBlue, size: 22),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Change password',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                    ),
                    Icon(
                      _passwordExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: Colors.blueGrey,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE8E8E8)),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _logout,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.logout_rounded, color: Colors.redAccent, size: 22),
                    SizedBox(width: 12),
                    Text(
                      'Log out',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.redAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton(
        onPressed: _saving ? null : _save,
        style: FilledButton.styleFrom(
          backgroundColor: _darkBlue,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: _saving
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text(
                'Save changes',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
      ),
    );
  }
}
