-- Per-rescuer SOS offers (pending / accepted / declined / expired).
-- Run after [sos_dispatches] and [profiles] exist.

create table if not exists public.sos_dispatch_offers (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null references public.sos_dispatches (id) on delete cascade,
  rescuer_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending'
    constraint sos_dispatch_offers_status_check check (
      status in ('pending', 'accepted', 'declined', 'expired')
    ),
  distance_m double precision,
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  unique (dispatch_id, rescuer_id)
);

create index if not exists sos_dispatch_offers_rescuer_status_idx
  on public.sos_dispatch_offers (rescuer_id, status, created_at desc);

create index if not exists sos_dispatch_offers_dispatch_idx
  on public.sos_dispatch_offers (dispatch_id);

alter table public.sos_dispatch_offers enable row level security;

-- Rescuers read their own offers.
create policy "sos_dispatch_offers_select_own"
  on public.sos_dispatch_offers for select
  using (auth.uid() = rescuer_id);

-- Inserts from trigger/service role bypass RLS; no insert policy for authenticated.
