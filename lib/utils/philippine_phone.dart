/// For the Philippines national segment field (digits after +63): strip spaces and
/// common pasted prefixes (`63…`, leading `0`) and cap at 10 digits.
String extractPhilippineNationalInputDigits(String input) {
  var d = input.replaceAll(RegExp(r'\D'), '');
  if (d.startsWith('63')) {
    d = d.substring(2);
  } else if (d.startsWith('0')) {
    d = d.substring(1);
  }
  if (d.length > 10) d = d.substring(0, 10);
  return d;
}

/// Formats exactly 10 national mobile digits as `XXX XXX XXXX`.
String formatPhilippineNationalMobileDisplay(String tenDigits) {
  if (tenDigits.isEmpty) return '';
  final b = StringBuffer();
  for (var i = 0; i < tenDigits.length; i++) {
    if (i == 3 || i == 6) b.write(' ');
    b.write(tenDigits[i]);
  }
  return b.toString();
}

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
