-- Mark an SOS dispatch as closed for the assigned rescuer.
-- Run this in Supabase SQL Editor after sos_dispatches + assigned_rescuer_id are present.

create or replace function public.set_dispatch_closed(
  p_dispatch_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_updated int := 0;
begin
  if v_uid is null then
    return false;
  end if;

  update public.sos_dispatches d
  set status = 'closed'
  where d.id = p_dispatch_id
    and d.assigned_rescuer_id = v_uid
    and d.status in ('dispatching', 'en_route', 'closed');

  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;

grant execute on function public.set_dispatch_closed(uuid) to authenticated;
