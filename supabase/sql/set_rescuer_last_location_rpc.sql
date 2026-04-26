-- Persist rescuer GPS on profiles when direct UPDATE is blocked by RLS (same pattern as set_rescuer_on_duty).
-- Run in Supabase SQL Editor after [profiles_rescuer_duty_location.sql].
--
-- Uses RETURNING into a variable (not IF NOT FOUND after UPDATE): in PL/pgSQL, NOT FOUND is for
-- SELECT INTO / FETCH, not reliably for UPDATE row counts.

create or replace function public.set_rescuer_last_location(
  p_latitude double precision,
  p_longitude double precision
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  update public.profiles
  set
    last_latitude = p_latitude,
    last_longitude = p_longitude,
    last_location_at = now()
  where id = auth.uid()
  returning id into v_id;

  if v_id is null then
    raise exception 'profile_not_found_or_forbidden';
  end if;
end;
$$;

comment on function public.set_rescuer_last_location(double precision, double precision) is
  'Updates last_latitude, last_longitude, last_location_at for the current user; bypasses RLS safely.';

revoke all on function public.set_rescuer_last_location(double precision, double precision) from public;
grant execute on function public.set_rescuer_last_location(double precision, double precision) to authenticated;
