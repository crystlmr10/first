-- Cebu 161 SOS rows inserted from the Flutter app after countdown + GPS.
-- ticket_number is assigned by trigger (SOS-001, SOS-002, …).
-- Run once in Supabase → SQL Editor.

create sequence if not exists public.sos_dispatch_ticket_seq;

create table if not exists public.sos_dispatches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  channel text not null default 'cebu_161'
    constraint sos_dispatches_channel_cebu check (channel = 'cebu_161'),
  latitude double precision not null,
  longitude double precision not null,
  accuracy_m double precision,
  submitted_at timestamptz not null default now(),
  status text not null default 'submitted'
    constraint sos_dispatches_status_check check (
      status in (
        'submitted',
        'received',
        'dispatching',
        'en_route',
        'closed'
      )
    ),
  ticket_number text not null unique
);

create index if not exists sos_dispatches_user_submitted_idx
  on public.sos_dispatches (user_id, submitted_at desc);

create or replace function public.sos_dispatches_set_ticket_number()
returns trigger
language plpgsql
as $$
begin
  if new.ticket_number is null or btrim(new.ticket_number) = '' then
    new.ticket_number :=
      'SOS-' || lpad(nextval('public.sos_dispatch_ticket_seq')::text, 3, '0');
  end if;
  return new;
end;
$$;

drop trigger if exists sos_dispatches_set_ticket_number on public.sos_dispatches;

create trigger sos_dispatches_set_ticket_number
  before insert on public.sos_dispatches
  for each row
  execute procedure public.sos_dispatches_set_ticket_number();

alter table public.sos_dispatches enable row level security;

create policy "sos_dispatches_insert_own"
  on public.sos_dispatches for insert
  with check (auth.uid() = user_id);

create policy "sos_dispatches_select_own"
  on public.sos_dispatches for select
  using (auth.uid() = user_id);

-- Realtime: Flutter .stream().eq('id', …) receives row updates (run migration on existing DBs too).
alter table public.sos_dispatches replica identity full;

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
