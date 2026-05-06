/// Password rules shared by [RegisterPage] and [PasswordRecoveryPage]
/// (Supabase-friendly strength: length + mixed character classes).
class PasswordPolicy {
  PasswordPolicy._();

  static final RegExp _upperRegex = RegExp(r'[A-Z]');
  static final RegExp _lowerRegex = RegExp(r'[a-z]');
  static final RegExp _digitRegex = RegExp(r'[0-9]');
  static final RegExp _symbolRegex =
      RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\\/;`~]');

  /// Same helper copy as the recovery screen subtitle.
  static const String requirementsHint =
      'Use at least 10 characters with uppercase, lowercase, number, and symbol.';

  /// Per-rule status for live UI (same checks as [validate]).
  static PasswordRequirementBreakdown analyze(String raw) {
    final password = raw.trim();
    return PasswordRequirementBreakdown(
      minLengthMet: password.length >= 10,
      uppercaseMet: _upperRegex.hasMatch(password),
      lowercaseMet: _lowerRegex.hasMatch(password),
      digitMet: _digitRegex.hasMatch(password),
      symbolMet: _symbolRegex.hasMatch(password),
    );
  }

  /// Returns null when valid; otherwise a short message for SnackBars.
  static String? validate(String raw) {
    final password = raw.trim();
    if (password.length < 10) {
      return 'Use at least 10 characters.';
    }
    if (!_upperRegex.hasMatch(password)) {
      return 'Include at least one uppercase letter.';
    }
    if (!_lowerRegex.hasMatch(password)) {
      return 'Include at least one lowercase letter.';
    }
    if (!_digitRegex.hasMatch(password)) {
      return 'Include at least one number.';
    }
    if (!_symbolRegex.hasMatch(password)) {
      return 'Include at least one special character.';
    }
    return null;
  }
}

/// Live checklist + strength segments (order matches [PasswordPolicy.validate]).
class PasswordRequirementBreakdown {
  const PasswordRequirementBreakdown({
    required this.minLengthMet,
    required this.uppercaseMet,
    required this.lowercaseMet,
    required this.digitMet,
    required this.symbolMet,
  });

  final bool minLengthMet;
  final bool uppercaseMet;
  final bool lowercaseMet;
  final bool digitMet;
  final bool symbolMet;

  /// Segment / checklist order.
  List<bool> get metFlags => [
        minLengthMet,
        uppercaseMet,
        lowercaseMet,
        digitMet,
        symbolMet,
      ];

  int get metCount => metFlags.where((m) => m).length;

  /// UI tiers for the strength bar (weak → medium → strong).
  PasswordStrengthTier get strengthTier {
    final n = metCount;
    if (n <= 2) return PasswordStrengthTier.weak;
    if (n <= 4) return PasswordStrengthTier.medium;
    return PasswordStrengthTier.strong;
  }
}

/// Maps [PasswordRequirementBreakdown.metCount] to red / orange / green strength UI.
enum PasswordStrengthTier {
  weak,
  medium,
  strong,
}
