// Shared login / registration identifier rules.
// Store profiles.email and profiles.username in lowercase for [.eq] lookups.
// Supabase Auth emails are lowercased on sign-in.

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
