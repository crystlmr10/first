import 'package:flutter/services.dart';

import 'philippine_phone.dart';

/// Keeps Philippine national mobile (`9XXXXXXXXX`) with live `XXX XXX XXXX` spacing.
class PhilippineNationalMobileInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) {
      return newValue.copyWith(text: '');
    }

    final digits = extractPhilippineNationalInputDigits(newValue.text);
    final formatted = formatPhilippineNationalMobileDisplay(digits);

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
