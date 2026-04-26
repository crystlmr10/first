-- Enforce at most one non-closed SOS row per user (Cebu 161 queue).
-- Run in Supabase → SQL Editor after [sos_dispatches] exists.
--
-- BEFORE YOU RUN
-- 1) If this errors with "duplicate key", you already have two or more open rows
--    for the same user_id. Fix data first, e.g.:
--       select user_id, status, count(*) from public.sos_dispatches
--       where status <> 'closed' group by user_id, status having count(*) > 1;
--    Or close/delete duplicates as appropriate.
-- 2) RLS is unchanged: users still insert/select only their own rows; this only
--    adds a uniqueness rule on (user_id) for rows where status is not 'closed'.

create unique index if not exists sos_dispatches_one_open_per_user_idx
  on public.sos_dispatches (user_id)
  where status <> 'closed';

comment on index public.sos_dispatches_one_open_per_user_idx is
  'Only one active SOS dispatch per user; multiple closed rows per user are allowed.';
