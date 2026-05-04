/// Philippine mobile numbers: national format `09XXXXXXXXX` or E.164 `+639XXXXXXXXX`.
///
/// **Sanitization:** All non-digits are stripped first (handles paste with spaces,
/// dashes, parentheses, plus signs, etc.), then the digit-only string is validated.
/// Returns E.164 `+63` + 10 digits starting with `9`, or `null` if invalid.
String? normalizePhilippineMobile(String raw) {
  final clean = raw.trim().replaceAll(RegExp(r'\D'), '');
  if (clean.isEmpty) return null;

  // `63` + 10 digits (e.g. pasted +63 917 123 4567 → 639171234567)
  if (clean.startsWith('63') && clean.length == 12) {
    final rest = clean.substring(2);
    if (rest.length == 10 && rest.startsWith('9')) {
      return '+63$rest';
    }
    return null;
  }

  // National 09XXXXXXXXX
  if (clean.length == 11 && clean.startsWith('09')) {
    final rest = clean.substring(1);
    if (rest.length == 10 && rest.startsWith('9')) {
      return '+63$rest';
    }
    return null;
  }

  // 10 digits, mobile (9XXXXXXXXX)
  if (clean.length == 10 && clean.startsWith('9')) {
    return '+63$clean';
  }

  return null;
}
