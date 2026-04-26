-- Status lifecycle + Realtime for sos_dispatches (run in Supabase SQL Editor if the table already exists).
-- New installs: prefer the updated [sos_dispatches.sql] which includes the CHECK.

-- Allowed status values (align with lib/utils/sos_dispatch_status.dart).
alter table public.sos_dispatches
  drop constraint if exists sos_dispatches_status_check;

alter table public.sos_dispatches
  add constraint sos_dispatches_status_check
  check (
    status in (
      'submitted',
      'received',
      'dispatching',
      'en_route',
      'closed'
    )
  );

-- Normalize any legacy values (adjust if you used different text).
update public.sos_dispatches
set status = 'submitted'
where status is null or trim(status) = '';

-- Realtime: receive UPDATE events for filtered subscriptions (Flutter .stream().eq('id', …)).
alter table public.sos_dispatches replica identity full;

-- Add table to the Realtime publication (idempotent pattern).
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'sos_dispatches'
  ) then
    alter publication supabase_realtime add table public.sos_dispatches;
  end if;
end $$;
