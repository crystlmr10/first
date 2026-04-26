-- Rescuer duty + last known location for SOS proximity matching (1 km).
-- Run in Supabase SQL Editor after [profiles] exists.

alter table public.profiles
  add column if not exists is_on_duty boolean not null default false,
  add column if not exists last_latitude double precision,
  add column if not exists last_longitude double precision,
  add column if not exists last_location_at timestamptz;

comment on column public.profiles.is_on_duty is
  'When true, rescuer can receive SOS offers within range.';
comment on column public.profiles.last_latitude is
  'Last reported latitude (WGS84) while on duty.';
comment on column public.profiles.last_longitude is
  'Last reported longitude (WGS84) while on duty.';
comment on column public.profiles.last_location_at is
  'Timestamp of last_location_* update; stale points are ignored for matching.';

create index if not exists profiles_rescuer_on_duty_idx
  on public.profiles (role, is_on_duty)
  where role = 'rescuer' and is_on_duty = true;
