-- Emergency type + caller phone for citizen SOS (see Citizen SOS plan).
-- Run in Supabase → SQL Editor after [sos_dispatches] exists.

alter table public.sos_dispatches
  add column if not exists emergency_main_category text,
  add column if not exists emergency_subcategory text,
  add column if not exists emergency_other_note text,
  add column if not exists caller_phone text;

comment on column public.sos_dispatches.emergency_main_category is
  'Stable key e.g. natural_disaster, medical, fire, crime, road_accident.';
comment on column public.sos_dispatches.emergency_subcategory is
  'Sub key e.g. flood, injury, other.';
comment on column public.sos_dispatches.emergency_other_note is
  'Free text when subcategory is other.';
comment on column public.sos_dispatches.caller_phone is
  'Snapshot E.164 Philippine mobile at SOS submit time.';
