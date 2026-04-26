-- FCM device tokens per user (rescuer/citizen) for push notifications.
-- Run after [profiles] exists.

create table if not exists public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  fcm_token text not null,
  platform text,
  updated_at timestamptz not null default now(),
  unique (user_id, fcm_token)
);

create index if not exists device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

create policy "device_tokens_select_own"
  on public.device_tokens for select
  using (auth.uid() = user_id);

create policy "device_tokens_insert_own"
  on public.device_tokens for insert
  with check (auth.uid() = user_id);

create policy "device_tokens_update_own"
  on public.device_tokens for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "device_tokens_delete_own"
  on public.device_tokens for delete
  using (auth.uid() = user_id);
