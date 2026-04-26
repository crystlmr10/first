-- Creates/updates public.profiles when a row is inserted into auth.users.
-- Needed when "Confirm email" is ON: after signUp the client often has no JWT yet,
-- so RLS blocks profiles.insert/upsert from the app. Username still lives in
-- raw_user_meta_data because signUp(..., data: { username: ... }).
--
-- Run once in Supabase → SQL Editor.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  uname text := lower(trim(coalesce(NEW.raw_user_meta_data->>'username', '')));
  phone text := nullif(trim(coalesce(NEW.raw_user_meta_data->>'phone_number', '')), '');
BEGIN
  INSERT INTO public.profiles (id, email, username, phone_number, role)
  VALUES (
    NEW.id,
    lower(trim(NEW.email)),
    NULLIF(uname, ''),
    phone,
    'user'
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    username = COALESCE(NULLIF(EXCLUDED.username, ''), public.profiles.username),
    phone_number = COALESCE(EXCLUDED.phone_number, public.profiles.phone_number),
    role = COALESCE(public.profiles.role, EXCLUDED.role);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE PROCEDURE public.handle_new_user();
