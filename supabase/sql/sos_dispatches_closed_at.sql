-- Record when a dispatch row becomes closed (for SOS History in the app).
-- Run in Supabase → SQL Editor after [sos_dispatches] exists.

alter table public.sos_dispatches
  add column if not exists closed_at timestamptz;

comment on column public.sos_dispatches.closed_at is
  'Set automatically when status first transitions to closed.';

-- Backfill: approximate close time for existing closed rows (optional).
update public.sos_dispatches
set closed_at = submitted_at
where status = 'closed'
  and closed_at is null;

create or replace function public.sos_dispatches_set_closed_at()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'closed' and (old.status is distinct from 'closed') then
    new.closed_at := coalesce(new.closed_at, now());
  end if;
  return new;
end;
$$;

drop trigger if exists sos_dispatches_set_closed_at on public.sos_dispatches;

create trigger sos_dispatches_set_closed_at
  before update on public.sos_dispatches
  for each row
  execute function public.sos_dispatches_set_closed_at();
