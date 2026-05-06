-- One-time migration: drop "Other" as a stored sex value (matches register_page.dart).
-- Run in Supabase → SQL Editor after deploying the app change.
--
-- 1) Rewrites legacy rows: "Other" → "Prefer not to say" (adjust if you prefer NULL).
-- 2) Updates auth.users metadata so it stays consistent with profiles.
-- 3) Replaces profiles_sex_check so "Other" is no longer allowed.

begin;

update public.profiles
set sex = 'Prefer not to say'
where sex = 'Other';

update auth.users
set raw_user_meta_data =
  coalesce(raw_user_meta_data, '{}'::jsonb)
  || jsonb_build_object('sex', 'Prefer not to say')
where coalesce(raw_user_meta_data->>'sex', '') = 'Other';

alter table public.profiles
  drop constraint if exists profiles_sex_check;

alter table public.profiles
  add constraint profiles_sex_check
  check (
    sex is null
    or sex in ('Male', 'Female', 'Prefer not to say')
  );

comment on column public.profiles.sex is 'Male | Female | Prefer not to say';

commit;
