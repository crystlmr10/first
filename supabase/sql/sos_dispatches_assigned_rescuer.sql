-- Optional assignee + rescuer read access via offers.
-- Run after [sos_dispatch_offers] exists.

alter table public.sos_dispatches
  add column if not exists assigned_rescuer_id uuid references public.profiles (id);

comment on column public.sos_dispatches.assigned_rescuer_id is
  'Rescuer who accepted first; null until accepted.';

create index if not exists sos_dispatches_assigned_rescuer_idx
  on public.sos_dispatches (assigned_rescuer_id)
  where assigned_rescuer_id is not null;

-- Rescuers may read a dispatch row if they have a relevant offer.
create policy "sos_dispatches_select_via_offer"
  on public.sos_dispatches for select
  using (
    exists (
      select 1
      from public.sos_dispatch_offers o
      where o.dispatch_id = sos_dispatches.id
        and o.rescuer_id = auth.uid()
        and o.status in ('pending', 'accepted')
    )
  );
