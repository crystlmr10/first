-- One-time migration: enforce unique username + phone on public.profiles.
-- Run in Supabase SQL Editor.
--
-- If this fails, clean duplicates first:
--   select lower(username), count(*) from public.profiles
--   where username is not null and length(trim(username)) > 0
--   group by 1 having count(*) > 1;
--
--   select phone_number, count(*) from public.profiles
--   where phone_number is not null and length(trim(phone_number)) > 0
--   group by 1 having count(*) > 1;

create unique index if not exists profiles_username_lower_uidx
  on public.profiles (lower(username))
  where username is not null and length(trim(username)) > 0;

create unique index if not exists profiles_phone_number_uidx
  on public.profiles (phone_number)
  where phone_number is not null and length(trim(phone_number)) > 0;

