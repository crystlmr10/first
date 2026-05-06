// Shared login / registration identifier rules.
// Store profiles.email and profiles.username in lowercase for [.eq] lookups.
// Supabase Auth emails are lowercased on sign-in.

import 'package:gotrue/gotrue.dart' show AuthException;
import 'package:postgrest/postgrest.dart' show PostgrestException;

String normalizeAuthIdentifier(String input) => input.trim().toLowerCase();

const String _emailConfirmRedirectUrlRaw = String.fromEnvironment(
  'EMAIL_CONFIRM_REDIRECT_URL',
  defaultValue: '',
);

/// Optional redirect destination after email confirmation.
/// Configure via --dart-define EMAIL_CONFIRM_REDIRECT_URL=...
String? emailConfirmRedirectUrl() {
  final url = _emailConfirmRedirectUrlRaw.trim();
  return url.isEmpty ? null : url;
}

/// Use for wrong password, unknown user, failed resolution — avoids enumeration.
const String kInvalidLoginCredentials =
    'Invalid login credentials. Please check your ID and password and try again.';

/// Use after successful Auth when [profiles.role] does not allow this entry point.
const String kAccessDenied = 'Access denied';

/// Sign-up did not finish (validation, auth policy, or network). Generic wording.
const String kRegistrationFailed =
    'Unable to complete registration. Check your information and try again.';

/// Auth user exists; user can continue to Sign in (profile may sync via trigger or later).
const String kRegistrationCreatedUseSignIn =
    'Your account was created. You can sign in.';

/// Title for the verification info panel on the login screen.
const String kEmailVerificationPanelTitle = 'Verify your email';

/// Shown on login when Auth refuses sign-in until email is confirmed.
const String kEmailNotVerifiedCannotLogin =
    'Your email is not verified yet. Open the link we emailed you, then try signing in again.';

/// Registration finished and the app has a session (profile saved).
const String kRegistrationSuccess = 'Registration complete.';

/// Normalizer rejected the input after digit sanitization.
const String kInvalidPhilippineMobile = 'Invalid Philippine mobile number.';

/// Email field failed basic format check (before Auth).
const String kRegistrationEmailInvalid = 'Enter a valid email address.';

/// Supabase Auth reports the email is already registered.
const String kRegistrationEmailInUse =
    'An account with this email already exists. Try signing in.';

/// Unique constraint or conflict involving phone on [profiles] (if enforced server-side).
const String kRegistrationPhoneInUse =
    'This phone number is already registered. Use a different number or sign in.';
const String kRegistrationUsernameInUse =
    'This username is already taken. Try a different username.';

/// Profile upsert failed with an ambiguous unique conflict.
const String kRegistrationProfileConflict =
    'Could not save your profile. One of your details may already be in use.';

/// Maps [AuthException] from sign-up to a specific user-facing message when possible.
String registrationAuthErrorMessage(AuthException e) {
  final raw = e.message;
  final m = e.message.toLowerCase();
  final c = (e.code ?? '').toLowerCase();
  const metadataPrefix = 'registration metadata invalid:';

  if (c == 'user_already_exists' ||
      c == 'email_exists' ||
      m.contains('user already registered') ||
      m.contains('already registered') ||
      m.contains('already been registered')) {
    return kRegistrationEmailInUse;
  }
  if (m.contains('username') &&
      (m.contains('taken') ||
          m.contains('exists') ||
          m.contains('already') ||
          m.contains('duplicate') ||
          m.contains('unique') ||
          m.contains('profiles_username_lower_uidx'))) {
    return kRegistrationUsernameInUse;
  }
  if (m.contains(metadataPrefix)) {
    final i = m.indexOf(metadataPrefix);
    final detail = raw.substring(i + metadataPrefix.length).trim();
    if (detail.isEmpty) {
      return 'Registration details are invalid. Please review your entries.';
    }
    final pretty = '${detail[0].toUpperCase()}${detail.substring(1)}';
    return pretty.endsWith('.') ? pretty : '$pretty.';
  }
  if (m.contains('phone') &&
      (m.contains('taken') ||
          m.contains('exists') ||
          m.contains('already'))) {
    return kRegistrationPhoneInUse;
  }
  if (c == 'weak_password' ||
      (m.contains('password') && m.contains('least'))) {
    return 'Password does not meet requirements. Try a stronger password.';
  }
  return kRegistrationFailed;
}

/// Privacy-friendly display of an email (customer-facing).
String maskEmailForDisplay(String email) {
  final trimmed = email.trim().toLowerCase();
  final at = trimmed.indexOf('@');
  if (at <= 0 || at >= trimmed.length - 1) return trimmed;
  final local = trimmed.substring(0, at);
  final domain = trimmed.substring(at + 1);
  if (local.isEmpty) return trimmed;
  if (local.length <= 2) {
    return '${local[0]}•••@$domain';
  }
  return '${local.substring(0, 2)}•••@$domain';
}

bool authExceptionIsEmailNotConfirmed(AuthException e) {
  final c = (e.code ?? '').toLowerCase();
  final m = e.message.toLowerCase();
  return c == 'email_not_confirmed' || m.contains('email not confirmed');
}

/// Maps [AuthException] from sign-in to a user-facing message when possible.
String loginAuthErrorMessage(AuthException e) {
  if (authExceptionIsEmailNotConfirmed(e)) {
    return kEmailNotVerifiedCannotLogin;
  }
  return kInvalidLoginCredentials;
}

/// Maps [PostgrestException] from profile upsert to a specific message when possible.
String registrationProfileErrorMessage(Object e) {
  if (e is! PostgrestException) return kRegistrationFailed;

  if (e.code == '23505') {
    final blob =
        '${e.message} ${e.details ?? ''} ${e.hint ?? ''}'.toLowerCase();
    if (blob.contains('username') || blob.contains('profiles_username_lower_uidx')) {
      return kRegistrationUsernameInUse;
    }
    if (blob.contains('phone')) return kRegistrationPhoneInUse;
    return kRegistrationProfileConflict;
  }

  return kRegistrationFailed;
}
