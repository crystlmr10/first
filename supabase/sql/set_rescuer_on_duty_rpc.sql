-- Reliable toggle for is_on_duty when direct client UPDATE is blocked by RLS quirks.
-- Run once in Supabase SQL Editor (after [profiles] and [profiles_rls_own_and_rescuer_read_citizen.sql]).

create or replace function public.set_rescuer_on_duty(p_on_duty boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v boolean;
begin
  update public.profiles
  set is_on_duty = p_on_duty
  where id = auth.uid()
  returning is_on_duty into v;

  if v is null then
    raise exception 'profile_not_found_or_forbidden';
  end if;

  return v;
end;
$$;

comment on function public.set_rescuer_on_duty(boolean) is
  'Sets profiles.is_on_duty for the current user only; bypasses RLS safely via SECURITY DEFINER.';

revoke all on function public.set_rescuer_on_duty(boolean) from public;
grant execute on function public.set_rescuer_on_duty(boolean) to authenticated;
