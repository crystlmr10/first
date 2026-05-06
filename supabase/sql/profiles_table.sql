-- Core [public.profiles] table (one row per auth user).
-- Run in Supabase → SQL Editor before:
--   profiles_on_auth_user_created.sql, profiles_rls_own_and_rescuer_read_citizen.sql,
--   profiles_rescuer_duty_location.sql (and other features that reference profiles).
-- Optional backfill: profiles_backfill_from_auth_metadata.sql
-- Safe to re-run: uses IF NOT EXISTS.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  username text,
  phone_number text,
  role text not null default 'user'
);

-- Optional: keep email searchable; app syncs email on upsert from the client.
create index if not exists profiles_email_lower_idx
  on public.profiles (lower(email));

-- Enforce unique username and phone number when provided.
create unique index if not exists profiles_username_lower_uidx
  on public.profiles (lower(username))
  where username is not null and length(trim(username)) > 0;

create unique index if not exists profiles_phone_number_uidx
  on public.profiles (phone_number)
  where phone_number is not null and length(trim(phone_number)) > 0;

comment on table public.profiles is
  'Floote profile: display name, phone, role. Filled by trigger and/or the mobile app.';

comment on column public.profiles.username is
  'Display name (from registration or Profile screen).';
comment on column public.profiles.phone_number is
  'E.164 Philippine mobile, e.g. +639171234567, or null.';
comment on column public.profiles.role is
  'Application role: user | rescuer (extend as needed).';
