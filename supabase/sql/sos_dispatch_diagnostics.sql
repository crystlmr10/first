-- Quick diagnostics for "status stays submitted / rescuer receives nothing".
-- Run in Supabase SQL Editor while testing.

-- 1) Last SOS dispatches and whether offers were generated.
select
  d.id,
  d.ticket_number,
  d.status,
  d.submitted_at,
  d.latitude,
  d.longitude,
  count(o.id) as offer_count
from public.sos_dispatches d
left join public.sos_dispatch_offers o on o.dispatch_id = d.id
group by d.id
order by d.submitted_at desc
limit 20;

-- 2) Rescuers that can be matched by trigger (role + duty + location freshness).
select
  p.id,
  p.username,
  p.is_on_duty,
  p.last_latitude,
  p.last_longitude,
  p.last_location_at,
  extract(epoch from (now() - p.last_location_at)) / 60.0 as mins_since_location
from public.profiles p
where p.role = 'rescuer'
order by p.last_location_at desc nulls last
limit 50;

-- 3) Ensure trigger exists and is enabled.
select
  t.tgname as trigger_name,
  c.relname as table_name,
  t.tgenabled as enabled,
  pg_get_triggerdef(t.oid) as trigger_def
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
where c.relname = 'sos_dispatches'
  and t.tgname = 'sos_dispatches_create_offers_on_insert';
