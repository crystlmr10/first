-- Harden user_reports data quality for safer reroute usage.
-- Safe + incremental: normalizes existing rows first, then adds defaults,
-- constraints, and indexes without deleting any data.

begin;

-- 1) Normalize existing values.
update public.user_reports
set admin_decision = lower(trim(coalesce(admin_decision, 'pending')))
where admin_decision is null
   or admin_decision <> lower(trim(coalesce(admin_decision, 'pending')));

update public.user_reports
set admin_decision = 'pending'
where admin_decision not in ('pending', 'passable', 'impassable');

-- Prevent blank strings from passing text checks.
update public.user_reports
set location_name = null
where trim(coalesce(location_name, '')) = '';

-- 2) Set defaults for future inserts.
alter table public.user_reports
  alter column created_at set default now();

alter table public.user_reports
  alter column admin_decision set default 'pending';

alter table public.user_reports
  alter column user_id set default auth.uid();

-- 3) Add constraints only if missing (idempotent).
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'user_reports_admin_decision_chk'
  ) then
    alter table public.user_reports
      add constraint user_reports_admin_decision_chk
      check (admin_decision in ('pending', 'passable', 'impassable'))
      not valid;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'user_reports_latitude_chk'
  ) then
    alter table public.user_reports
      add constraint user_reports_latitude_chk
      check (latitude is not null and latitude between -90 and 90)
      not valid;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'user_reports_longitude_chk'
  ) then
    alter table public.user_reports
      add constraint user_reports_longitude_chk
      check (longitude is not null and longitude between -180 and 180)
      not valid;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'user_reports_location_name_chk'
  ) then
    alter table public.user_reports
      add constraint user_reports_location_name_chk
      check (location_name is not null and length(trim(location_name)) > 0)
      not valid;
  end if;
end $$;

-- 4) Validate constraints after normalization.
alter table public.user_reports
  validate constraint user_reports_admin_decision_chk;

alter table public.user_reports
  validate constraint user_reports_latitude_chk;

alter table public.user_reports
  validate constraint user_reports_longitude_chk;

alter table public.user_reports
  validate constraint user_reports_location_name_chk;

-- 5) Keep insert/update values normalized.
create or replace function public.normalize_user_reports()
returns trigger
language plpgsql
as $$
begin
  new.location_name := nullif(trim(coalesce(new.location_name, '')), '');
  new.user_comments := nullif(trim(coalesce(new.user_comments, '')), '');
  new.admin_decision := lower(trim(coalesce(new.admin_decision, 'pending')));

  if new.admin_decision is null or new.admin_decision = '' then
    new.admin_decision := 'pending';
  end if;

  if new.location_name is not null
     and lower(new.location_name) = 'current location'
     and new.latitude is not null
     and new.longitude is not null then
    new.location_name :=
      'Near '
      || trim(to_char(new.latitude, 'FM999990.000000'))
      || ', '
      || trim(to_char(new.longitude, 'FM999990.000000'));
  end if;

  return new;
end;
$$;

drop trigger if exists trg_normalize_user_reports on public.user_reports;

create trigger trg_normalize_user_reports
before insert or update on public.user_reports
for each row
execute function public.normalize_user_reports();

-- 6) Helpful indexes for map/reroute queries.
create index if not exists user_reports_created_at_idx
  on public.user_reports (created_at desc);

create index if not exists user_reports_admin_decision_idx
  on public.user_reports (admin_decision);

create index if not exists user_reports_impassable_created_at_idx
  on public.user_reports (created_at desc)
  where admin_decision = 'impassable';

commit;
