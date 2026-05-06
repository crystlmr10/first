import 'package:flutter/material.dart';

import '../utils/password_policy.dart';

/// Live password checklist + 3-tier strength bar driven by [PasswordPolicy.analyze].
///
/// Shown only while [focusNode] has focus or [controller] has text.
/// Unmet rules: gray text + ✕; met rules: green text + ✓.
/// Strength: Weak (red) / Medium (orange) / Strong (green).
class PasswordRequirementsPanel extends StatelessWidget {
  const PasswordRequirementsPanel({
    super.key,
    required this.controller,
    required this.focusNode,
    this.dense = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool dense;

  static const Color _metGreen = Color(0xFF2E7D32);
  static const Color _defaultGray = Color(0xFF757575);
  static const Color _segmentIdle = Color(0xFFE0E0E0);
  static const Color _weakRed = Color(0xFFC62828);
  static const Color _mediumOrange = Color(0xFFEF6C00);

  static const List<String> _labels = [
    'At least 10 characters',
    'One uppercase letter',
    'One lowercase letter',
    'One number',
    'One special character',
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, focusNode]),
      builder: (context, _) {
        final visible =
            focusNode.hasFocus || controller.text.isNotEmpty;
        if (!visible) return const SizedBox.shrink();

        final breakdown = PasswordPolicy.analyze(controller.text);
        final flags = breakdown.metFlags;
        final tier = breakdown.strengthTier;

        final segmentHeight = dense ? 6.0 : 8.0;
        final gap = dense ? 5.0 : 6.0;
        final fontSize = dense ? 12.5 : 13.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _StrengthSegmentsRow(
              tier: tier,
              segmentHeight: segmentHeight,
              gap: gap,
            ),
            SizedBox(height: dense ? 6 : 8),
            Text(
              _tierLabel(tier),
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w700,
                color: _tierColor(tier),
              ),
            ),
            SizedBox(height: dense ? 10 : 14),
            ...List.generate(_labels.length, (i) {
              final met = flags[i];
              return Padding(
                padding:
                    EdgeInsets.only(bottom: i < _labels.length - 1 ? 6 : 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        met ? Icons.check : Icons.close,
                        size: 18,
                        color: met ? _metGreen : _defaultGray,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _labels[i],
                        style: TextStyle(
                          fontSize: fontSize,
                          height: 1.35,
                          color: met ? _metGreen : _defaultGray,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        );
      },
    );
  }

  static String _tierLabel(PasswordStrengthTier tier) {
    switch (tier) {
      case PasswordStrengthTier.weak:
        return 'Weak';
      case PasswordStrengthTier.medium:
        return 'Medium';
      case PasswordStrengthTier.strong:
        return 'Strong';
    }
  }

  static Color _tierColor(PasswordStrengthTier tier) {
    switch (tier) {
      case PasswordStrengthTier.weak:
        return _weakRed;
      case PasswordStrengthTier.medium:
        return _mediumOrange;
      case PasswordStrengthTier.strong:
        return _metGreen;
    }
  }
}

class _StrengthSegmentsRow extends StatelessWidget {
  const _StrengthSegmentsRow({
    required this.tier,
    required this.segmentHeight,
    required this.gap,
  });

  final PasswordStrengthTier tier;
  final double segmentHeight;
  final double gap;

  static const Color _idle = PasswordRequirementsPanel._segmentIdle;
  static const Color _weak = PasswordRequirementsPanel._weakRed;
  static const Color _medium = PasswordRequirementsPanel._mediumOrange;
  static const Color _strong = PasswordRequirementsPanel._metGreen;

  @override
  Widget build(BuildContext context) {
    // Three segments: cumulative fill reflects weak / medium / strong.
    Color colorForIndex(int i) {
      switch (tier) {
        case PasswordStrengthTier.weak:
          return i == 0 ? _weak : _idle;
        case PasswordStrengthTier.medium:
          return i <= 1 ? _medium : _idle;
        case PasswordStrengthTier.strong:
          return _strong;
      }
    }

    return Row(
      children: List.generate(3, (i) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < 2 ? gap : 0),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              height: segmentHeight,
              decoration: BoxDecoration(
                color: colorForIndex(i),
                borderRadius: BorderRadius.circular(segmentHeight / 2),
              ),
            ),
          ),
        );
      }),
    );
  }
}
