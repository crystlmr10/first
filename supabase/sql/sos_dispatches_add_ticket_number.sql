-- Run this if you already created sos_dispatches WITHOUT ticket_number.

create sequence if not exists public.sos_dispatch_ticket_seq;

alter table public.sos_dispatches
  add column if not exists ticket_number text;

do $$
declare r record;
begin
  for r in
    select id from public.sos_dispatches where ticket_number is null order by submitted_at
  loop
    update public.sos_dispatches
    set ticket_number = 'SOS-' || lpad(nextval('public.sos_dispatch_ticket_seq')::text, 3, '0')
    where id = r.id;
  end loop;
end $$;

alter table public.sos_dispatches
  alter column ticket_number set not null;

create unique index if not exists sos_dispatches_ticket_number_uq
  on public.sos_dispatches (ticket_number);

create or replace function public.sos_dispatches_set_ticket_number()
returns trigger
language plpgsql
as $$
begin
  if new.ticket_number is null or btrim(new.ticket_number) = '' then
    new.ticket_number :=
      'SOS-' || lpad(nextval('public.sos_dispatch_ticket_seq')::text, 3, '0');
  end if;
  return new;
end;
$$;

drop trigger if exists sos_dispatches_set_ticket_number on public.sos_dispatches;

create trigger sos_dispatches_set_ticket_number
  before insert on public.sos_dispatches
  for each row
  execute procedure public.sos_dispatches_set_ticket_number();
