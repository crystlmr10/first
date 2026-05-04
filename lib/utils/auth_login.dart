// Shared login / registration identifier rules.
// Store profiles.email and profiles.username in lowercase for [.eq] lookups.
// Supabase Auth emails are lowercased on sign-in.

import 'package:gotrue/gotrue.dart' show AuthException;
import 'package:postgrest/postgrest.dart' show PostgrestException;

String normalizeAuthIdentifier(String input) => input.trim().toLowerCase();

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

/// Profile upsert failed with an ambiguous unique conflict.
const String kRegistrationProfileConflict =
    'Could not save your profile. One of your details may already be in use.';

/// Maps [AuthException] from sign-up to a specific user-facing message when possible.
String registrationAuthErrorMessage(AuthException e) {
  final m = e.message.toLowerCase();
  final c = (e.code ?? '').toLowerCase();

  if (c == 'user_already_exists' ||
      c == 'email_exists' ||
      m.contains('user already registered') ||
      m.contains('already registered') ||
      m.contains('already been registered')) {
    return kRegistrationEmailInUse;
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

/// Maps [PostgrestException] from profile upsert to a specific message when possible.
String registrationProfileErrorMessage(Object e) {
  if (e is! PostgrestException) return kRegistrationFailed;

  if (e.code == '23505') {
    final blob =
        '${e.message} ${e.details ?? ''} ${e.hint ?? ''}'.toLowerCase();
    if (blob.contains('phone')) return kRegistrationPhoneInUse;
    return kRegistrationProfileConflict;
  }

  return kRegistrationFailed;
}
