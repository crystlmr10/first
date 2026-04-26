-- After INSERT on sos_dispatches: create pending offers for on-duty rescuers.
-- Matching was previously strict (<= 1 km and location <= 15 min old), which made
-- many real/emulator flows stay at status='submitted' with zero offers.
-- This version is intentionally more forgiving for production resiliency/testing:
--   - radius: 10 km
--   - location freshness: 60 minutes
-- RPC for rescuer accept/decline. Run after [sos_dispatch_offers] and [sos_dispatches_assigned_rescuer.sql].

create or replace function public.sos_dispatches_create_offers_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_offers_inserted int;
  v_max_distance_m double precision := 10000.0; -- 10 km
  v_max_location_age interval := interval '60 minutes';
begin
  insert into public.sos_dispatch_offers (
    dispatch_id,
    rescuer_id,
    status,
    distance_m,
    created_at
  )
  select
    new.id,
    p.id,
    'pending',
    (
      6371000.0 * acos(
        least(
          1.0,
          greatest(
            -1.0,
            sin(radians(p.last_latitude)) * sin(radians(new.latitude))
            + cos(radians(p.last_latitude)) * cos(radians(new.latitude))
            * cos(radians(p.last_longitude - new.longitude))
          )
        )
      )
    ),
    now()
  from public.profiles p
  where p.role = 'rescuer'
    and coalesce(p.is_on_duty, false) = true
    and p.last_latitude is not null
    and p.last_longitude is not null
    and p.last_location_at is not null
    and p.last_location_at > (now() - v_max_location_age)
    and (
      6371000.0 * acos(
        least(
          1.0,
          greatest(
            -1.0,
            sin(radians(p.last_latitude)) * sin(radians(new.latitude))
            + cos(radians(p.last_latitude)) * cos(radians(new.latitude))
            * cos(radians(p.last_longitude - new.longitude))
          )
        )
      )
    ) <= v_max_distance_m
  on conflict (dispatch_id, rescuer_id) do nothing;

  get diagnostics v_offers_inserted = row_count;

  -- Citizen stepper: Sent → Received once at least one on-duty rescuer gets an offer (same moment as notify).
  -- Accept still moves received → dispatching via [respond_sos_offer].
  if v_offers_inserted > 0 then
    update public.sos_dispatches
    set status = 'received'
    where id = new.id
      and status = 'submitted';
  end if;

  return new;
end;
$$;

drop trigger if exists sos_dispatches_create_offers_on_insert on public.sos_dispatches;

create trigger sos_dispatches_create_offers_on_insert
  after insert on public.sos_dispatches
  for each row
  execute procedure public.sos_dispatches_create_offers_after_insert();

-- Rescuer accept/decline (first accept wins).
create or replace function public.respond_sos_offer(
  p_offer_id uuid,
  p_accept boolean
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rescuer uuid := auth.uid();
  v_dispatch uuid;
  v_updated int;
begin
  if v_rescuer is null then
    return json_build_object('ok', false, 'error', 'not_authenticated');
  end if;

  select dispatch_id into v_dispatch
  from public.sos_dispatch_offers
  where id = p_offer_id and rescuer_id = v_rescuer;

  if v_dispatch is null then
    return json_build_object('ok', false, 'error', 'offer_not_found');
  end if;

  if not p_accept then
    update public.sos_dispatch_offers
    set status = 'declined', responded_at = now()
    where id = p_offer_id and rescuer_id = v_rescuer;
    return json_build_object('ok', true, 'accepted', false);
  end if;

  update public.sos_dispatches d
  set
    assigned_rescuer_id = v_rescuer,
    status = 'dispatching'
  where d.id = v_dispatch
    and d.assigned_rescuer_id is null;

  get diagnostics v_updated = row_count;

  if v_updated = 0 then
    update public.sos_dispatch_offers
    set status = 'declined', responded_at = now()
    where id = p_offer_id and rescuer_id = v_rescuer;
    return json_build_object(
      'ok', false,
      'accepted', false,
      'error', 'already_assigned'
    );
  end if;

  update public.sos_dispatch_offers
  set status = 'accepted', responded_at = now()
  where id = p_offer_id;

  update public.sos_dispatch_offers
  set status = 'expired', responded_at = coalesce(responded_at, now())
  where dispatch_id = v_dispatch
    and rescuer_id <> v_rescuer
    and status = 'pending';

  return json_build_object('ok', true, 'accepted', true);
end;
$$;

grant execute on function public.respond_sos_offer(uuid, boolean) to authenticated;

-- Realtime for rescuer inbox.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'sos_dispatch_offers'
  ) then
    alter publication supabase_realtime add table public.sos_dispatch_offers;
  end if;
end $$;

alter table public.sos_dispatch_offers replica identity full;
