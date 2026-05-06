import 'package:flutter/material.dart';

/// Under confirm password: shows match/mismatch only (no strength checklist).
///
/// Visible while the confirm field is focused or has text.
class PasswordConfirmMatchPanel extends StatelessWidget {
  const PasswordConfirmMatchPanel({
    super.key,
    required this.passwordController,
    required this.confirmController,
    required this.confirmFocusNode,
    this.dense = true,
  });

  final TextEditingController passwordController;
  final TextEditingController confirmController;
  final FocusNode confirmFocusNode;
  final bool dense;

  static const Color _matchGreen = Color(0xFF2E7D32);
  static const Color _mismatchRed = Color(0xFFC62828);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        passwordController,
        confirmController,
        confirmFocusNode,
      ]),
      builder: (context, _) {
        final visible = confirmFocusNode.hasFocus ||
            confirmController.text.isNotEmpty;
        if (!visible) return const SizedBox.shrink();

        final password = passwordController.text.trim();
        final confirm = confirmController.text.trim();

        if (confirm.isEmpty) {
          return Padding(
            padding: EdgeInsets.only(top: dense ? 10 : 12),
            child: Text(
              'Re-enter your password to confirm.',
              style: TextStyle(
                fontSize: dense ? 12.5 : 13.0,
                color: Colors.grey.shade600,
                height: 1.35,
              ),
            ),
          );
        }

        final match = password.isNotEmpty && password == confirm;
        final double fontSize = dense ? 12.5 : 13.0;

        return Padding(
          padding: EdgeInsets.only(top: dense ? 10 : 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  match ? Icons.check_circle_outline : Icons.cancel_outlined,
                  size: 20,
                  color: match ? _matchGreen : _mismatchRed,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  match ? 'Passwords match' : 'Passwords do not match',
                  style: TextStyle(
                    fontSize: fontSize,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: match ? _matchGreen : _mismatchRed,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
