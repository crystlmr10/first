-- Optional one-time backfill: copy username / phone from auth.users raw_user_meta_data
-- into [public.profiles] for accounts created before the trigger or when rows were incomplete.
-- Run after [profiles_table.sql] and [profiles_on_auth_user_created.sql].
-- Review results in Table Editor before running in production.

update public.profiles p
set
  username = case
    when nullif(trim(coalesce(p.username, '')), '') is not null then p.username
    else nullif(trim(coalesce(au.raw_user_meta_data->>'username', '')), '')
  end,
  phone_number = case
    when nullif(trim(coalesce(p.phone_number, '')), '') is not null then p.phone_number
    else nullif(trim(coalesce(au.raw_user_meta_data->>'phone_number', '')), '')
  end,
  email = coalesce(nullif(trim(coalesce(p.email, '')), ''), lower(trim(au.email::text)))
from auth.users au
where p.id = au.id;
