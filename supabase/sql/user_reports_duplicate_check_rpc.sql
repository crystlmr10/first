-- Check whether a flood report already exists near a point in a recent window.
-- Run in Supabase SQL Editor.

create or replace function public.is_duplicate_flood_report(
  p_lat double precision,
  p_lng double precision,
  p_radius_m integer default 120,
  p_window_minutes integer default 180
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exists boolean := false;
begin
  if p_lat is null or p_lng is null then
    return false;
  end if;

  select exists (
    select 1
    from public.user_reports r
    where r.latitude is not null
      and r.longitude is not null
      and lower(coalesce(r.admin_decision, 'pending')) in ('pending', 'impassable', 'risky')
      and r.created_at >= now() - make_interval(mins => greatest(1, p_window_minutes))
      and (
        6371000 * acos(
          least(
            1.0,
            greatest(
              -1.0,
              cos(radians(p_lat)) * cos(radians(r.latitude)) *
              cos(radians(r.longitude) - radians(p_lng)) +
              sin(radians(p_lat)) * sin(radians(r.latitude))
            )
          )
        )
      ) <= greatest(1, p_radius_m)
  )
  into v_exists;

  return coalesce(v_exists, false);
end;
$$;

grant execute on function public.is_duplicate_flood_report(double precision, double precision, integer, integer) to authenticated;
