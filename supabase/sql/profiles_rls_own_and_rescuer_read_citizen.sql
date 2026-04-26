-- RLS on [profiles]: own row CRUD for authenticated users + rescuer SELECT for citizens with an SOS offer.
-- Run after [sos_dispatch_offers] exists. If you already have RLS policies, merge carefully or rename conflicts.
--
-- Note: the rescuer policy allows reading the full matching citizen [profiles] row (not just username).
-- To expose only username, use a SQL view or an RPC instead.

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "profiles_insert_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
drop policy if exists "profiles_select_citizen_when_sos_offer" on public.profiles;

-- Any signed-in user can read/update their own profile (registration, dashboard, duty/location).
create policy "profiles_select_own"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id);

create policy "profiles_insert_own"
  on public.profiles for insert
  to authenticated
  with check (auth.uid() = id);

create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id)
  with check (auth.uid() = id);

-- Rescuers can read a citizen's profile if that citizen has an SOS dispatch offered to this rescuer.
create policy "profiles_select_citizen_when_sos_offer"
  on public.profiles for select
  to authenticated
  using (
    exists (
      select 1
      from public.sos_dispatch_offers o
      join public.sos_dispatches d on d.id = o.dispatch_id
      where o.rescuer_id = auth.uid()
        and d.user_id = profiles.id
    )
  );

comment on policy "profiles_select_citizen_when_sos_offer" on public.profiles is
  'Lets rescuers load citizen username (and other columns) for SOS offers directed to them.';
