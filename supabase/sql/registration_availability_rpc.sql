-- Public RPC for debounced registration availability checks.
-- Allows anon/authenticated clients to check username/phone availability
-- without exposing full profile rows.

create or replace function public.check_registration_availability(
  p_username text default null,
  p_phone_number text default null,
  p_email text default null
)
returns table (
  username_taken boolean,
  phone_taken boolean,
  email_taken boolean
)
language sql
security definer
set search_path = public
as $$
  select
    case
      when p_username is null or length(trim(p_username)) = 0 then false
      else exists (
        select 1
        from public.profiles p
        where lower(p.username) = lower(trim(p_username))
      )
    end as username_taken,
    case
      when p_phone_number is null or length(trim(p_phone_number)) = 0 then false
      else exists (
        select 1
        from public.profiles p
        where p.phone_number = trim(p_phone_number)
      )
    end as phone_taken,
    case
      when p_email is null or length(trim(p_email)) = 0 then false
      else exists (
        select 1
        from public.profiles p
        where lower(p.email) = lower(trim(p_email))
      )
    end as email_taken;
$$;

revoke all on function public.check_registration_availability(text, text, text)
  from public;
grant execute on function public.check_registration_availability(text, text, text)
  to anon, authenticated;

