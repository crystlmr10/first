-- Enforce required/valid registration metadata before profile creation.
-- Run this in Supabase SQL Editor to apply immediately to existing projects.

alter table public.profiles
  drop constraint if exists profiles_date_of_birth_valid_range_check;

alter table public.profiles
  add constraint profiles_date_of_birth_valid_range_check
  check (
    date_of_birth is null
    or (
      date_of_birth >= (current_date - interval '120 years')::date
      and date_of_birth <= (current_date - interval '13 years')::date
    )
  );

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  uname text := lower(trim(coalesce(new.raw_user_meta_data->>'username', '')));
  phone text := nullif(trim(coalesce(new.raw_user_meta_data->>'phone_number', '')), '');
  gname text := nullif(trim(coalesce(new.raw_user_meta_data->>'given_name', '')), '');
  mname text := nullif(trim(coalesce(new.raw_user_meta_data->>'middle_name', '')), '');
  lname text := nullif(trim(coalesce(new.raw_user_meta_data->>'last_name', '')), '');
  fname text := nullif(trim(coalesce(new.raw_user_meta_data->>'full_name', '')), '');
  sex_val text := nullif(trim(coalesce(new.raw_user_meta_data->>'sex', '')), '');
  dob_raw text := nullif(trim(coalesce(new.raw_user_meta_data->>'date_of_birth', '')), '');
  dob_val date;
begin
  if uname = '' then
    uname := null;
  end if;

  if uname is null
     or gname is null
     or lname is null
     or phone is null
     or dob_raw is null
     or sex_val is null then
    raise exception using
      errcode = '22023',
      message = 'registration metadata invalid: missing required fields';
  end if;

  if phone !~ '^\+639\d{9}$' then
    raise exception using
      errcode = '22023',
      message = 'registration metadata invalid: phone must be +639XXXXXXXXX';
  end if;

  if sex_val not in ('Male', 'Female', 'Prefer not to say') then
    raise exception using
      errcode = '22023',
      message = 'registration metadata invalid: sex value is not allowed';
  end if;

  if dob_raw !~ '^\d{2}/\d{2}/\d{4}$' then
    raise exception using
      errcode = '22023',
      message = 'registration metadata invalid: date of birth must be MM/DD/YYYY';
  end if;

  dob_val := to_date(dob_raw, 'MM/DD/YYYY');
  if to_char(dob_val, 'MM/DD/YYYY') <> dob_raw then
    raise exception using
      errcode = '22023',
      message = 'registration metadata invalid: date of birth is not a real date';
  end if;

  if dob_val < (current_date - interval '120 years')::date
     or dob_val > (current_date - interval '13 years')::date then
    raise exception using
      errcode = '22023',
      message = 'registration metadata invalid: date of birth must be between 13 and 120 years old';
  end if;

  if fname is null then
    fname := concat_ws(' ', gname, mname, lname);
  end if;

  insert into public.profiles (
    id,
    email,
    username,
    phone_number,
    role,
    given_name,
    middle_name,
    last_name,
    full_name,
    date_of_birth,
    sex
  )
  values (
    new.id,
    lower(trim(new.email)),
    uname,
    phone,
    'user',
    gname,
    mname,
    lname,
    fname,
    dob_val,
    sex_val
  )
  on conflict (id) do update set
    email = excluded.email,
    username = coalesce(nullif(excluded.username, ''), public.profiles.username),
    phone_number = coalesce(excluded.phone_number, public.profiles.phone_number),
    role = coalesce(public.profiles.role, excluded.role),
    given_name = coalesce(excluded.given_name, public.profiles.given_name),
    middle_name = coalesce(excluded.middle_name, public.profiles.middle_name),
    last_name = coalesce(excluded.last_name, public.profiles.last_name),
    full_name = coalesce(excluded.full_name, public.profiles.full_name),
    date_of_birth = coalesce(excluded.date_of_birth, public.profiles.date_of_birth),
    sex = coalesce(excluded.sex, public.profiles.sex);

  return new;
end;
$$;

