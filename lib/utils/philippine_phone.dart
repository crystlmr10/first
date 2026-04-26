/// Philippine mobile numbers: national format `09XXXXXXXXX` or E.164 `+639XXXXXXXXX`.
/// Returns E.164 `+63` + 10 digits starting with `9`, or `null` if invalid.
String? normalizePhilippineMobile(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  var s = trimmed.replaceAll(RegExp(r'[\s\-]'), '');
  String digits;
  if (s.startsWith('+')) {
    digits = s.substring(1).replaceAll(RegExp(r'\D'), '');
  } else {
    digits = s.replaceAll(RegExp(r'\D'), '');
  }
  if (digits.isEmpty) return null;

  // +63 9XX XXX XXXX -> 63 + 10 digits (12 total)
  if (digits.startsWith('63')) {
    final rest = digits.substring(2);
    if (rest.length == 10 && rest.startsWith('9')) {
      return '+63$rest';
    }
    return null;
  }

  // 09XX XXX XXXX
  if (digits.startsWith('0') && digits.length == 11 && digits.startsWith('09')) {
    final rest = digits.substring(1);
    if (rest.length == 10 && rest.startsWith('9')) {
      return '+63$rest';
    }
    return null;
  }

  // 9XX XXX XXXX (10 digits, mobile)
  if (digits.length == 10 && digits.startsWith('9')) {
    return '+63$digits';
  }

  return null;
}
