-- Two-Hearts Servant Community database schema
-- Run this entire file in Supabase Dashboard > SQL Editor.
-- Do NOT put the Supabase service_role key in any browser file.

create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('member', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.event_status as enum ('Draft', 'Open', 'Full', 'Postponed', 'Cancelled', 'Completed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.registration_status as enum ('Pending', 'Confirmed', 'Cancelled');
exception when duplicate_object then null; end $$;

-- Safe upgrades for projects that already created the earlier schema.
alter type public.event_status add value if not exists 'Postponed';
alter type public.event_status add value if not exists 'Cancelled';

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  role public.app_role not null default 'member',
  created_at timestamptz not null default now()
);

create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 2 and 160),
  description text not null default '',
  event_date date not null,
  event_time text not null default '',
  location text not null default '',
  capacity integer not null check (capacity > 0 and capacity <= 10000),
  ministry_needs jsonb not null default '{}'::jsonb check (jsonb_typeof(ministry_needs) = 'object'),
  registered_count integer not null default 0 check (registered_count >= 0),
  status public.event_status not null default 'Draft',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.registrations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  full_name text not null check (length(trim(full_name)) between 2 and 160),
  contact text not null check (length(trim(contact)) between 3 and 200),
  ministry text not null check (length(trim(ministry)) between 2 and 100),
  role text not null check (length(trim(role)) between 2 and 100),
  availability text not null check (availability in ('Morning','Afternoon','Evenings','Flexible')),
  notes text not null default '' check (length(notes) <= 2000),
  status public.registration_status not null default 'Pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.events add column if not exists ministry_needs jsonb not null default '{}'::jsonb;

create index if not exists events_date_status_idx on public.events(event_date, status);
do $$ begin
  alter table public.registrations drop constraint if exists registrations_event_id_fkey;
  alter table public.registrations add constraint registrations_event_id_fkey foreign key (event_id) references public.events(id) on delete cascade;
exception when duplicate_object then null; end $$;

create index if not exists registrations_user_created_idx on public.registrations(user_id, created_at desc);
create index if not exists registrations_event_status_idx on public.registrations(event_id, status);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'); $$;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles(id, display_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name',''), 'member')
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users
for each row execute function public.create_profile_for_new_user();

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists events_touch_updated_at on public.events;
create trigger events_touch_updated_at before update on public.events for each row execute function public.touch_updated_at();
drop trigger if exists registrations_touch_updated_at on public.registrations;
create trigger registrations_touch_updated_at before update on public.registrations for each row execute function public.touch_updated_at();

-- Serialize applications and enforce both event-wide and ministry-specific limits.
create or replace function public.check_registration_capacity()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  ev public.events%rowtype;
  active_count integer;
  ministry_count integer;
  ministry_target integer;
begin
  select * into ev from public.events where id = new.event_id for update;
  if not found then raise exception 'This event is no longer available.'; end if;
  if ev.status <> 'Open' then raise exception 'Applications are closed for this event.'; end if;
  select count(*) into active_count from public.registrations
    where event_id = new.event_id and status in ('Pending','Confirmed');
  if active_count >= ev.capacity then raise exception 'This event has reached overall capacity.'; end if;
  if not (ev.ministry_needs ? new.ministry) then
    raise exception 'This ministry is not requested for this event.';
  end if;
  ministry_target := greatest(1, coalesce((ev.ministry_needs->>new.ministry)::integer, 1));
  select count(*) into ministry_count from public.registrations
    where event_id = new.event_id and ministry = new.ministry and status in ('Pending','Confirmed');
  if ministry_count >= ministry_target then
    raise exception 'This ministry has reached its volunteer target for this event.';
  end if;
  return new;
end; $$;
drop trigger if exists registrations_capacity_guard on public.registrations;
create trigger registrations_capacity_guard before insert on public.registrations
for each row execute function public.check_registration_capacity();

-- Return only aggregate ministry counts, never volunteer names or contact details.
create or replace function public.get_public_event_ministry_counts()
returns table(event_id uuid, ministry text, active_count bigint)
language sql stable security definer set search_path = public as $$
  select r.event_id, r.ministry, count(*) as active_count
  from public.registrations r
  join public.events e on e.id = r.event_id
  where r.status in ('Pending','Confirmed') and e.status <> 'Draft'
  group by r.event_id, r.ministry;
$$;
grant execute on function public.get_public_event_ministry_counts() to anon, authenticated;

-- Members may cancel their own application without being able to edit other fields.
create or replace function public.cancel_my_registration(target_registration uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update public.registrations
    set status = 'Cancelled'
    where id = target_registration and user_id = auth.uid() and status in ('Pending','Confirmed');
  if not found then raise exception 'Application not found or it can no longer be cancelled.'; end if;
end; $$;
grant execute on function public.cancel_my_registration(uuid) to authenticated;

create or replace function public.refresh_event_registered_count()
returns trigger language plpgsql security definer set search_path = public as $$
declare target_event uuid;
begin
  target_event := case when tg_op = 'DELETE' then old.event_id else new.event_id end;
  update public.events e set registered_count = (
    select count(*) from public.registrations r where r.event_id = target_event and r.status in ('Pending','Confirmed')
  ) where e.id = target_event;
  if tg_op = 'UPDATE' and old.event_id is distinct from new.event_id then
    update public.events e set registered_count = (
      select count(*) from public.registrations r where r.event_id = old.event_id and r.status in ('Pending','Confirmed')
    ) where e.id = old.event_id;
  end if;
  if tg_op = 'DELETE' then return old; else return new; end if;
end; $$;
drop trigger if exists registrations_refresh_count on public.registrations;
create trigger registrations_refresh_count after insert or update or delete on public.registrations
for each row execute function public.refresh_event_registered_count();

alter table public.profiles enable row level security;
alter table public.events enable row level security;
alter table public.registrations enable row level security;

-- Public visitors may read published event statuses, but never drafts.
drop policy if exists "Published events are readable" on public.events;
create policy "Published events are readable" on public.events for select
using (status <> 'Draft' or public.is_admin());
drop policy if exists "Admins create events" on public.events;
create policy "Admins create events" on public.events for insert to authenticated
with check (public.is_admin());
drop policy if exists "Admins update events" on public.events;
create policy "Admins update events" on public.events for update to authenticated
using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Admins delete events" on public.events;
create policy "Admins delete events" on public.events for delete to authenticated
using (public.is_admin());

-- Members may see their own profile. Only admins can read other profiles or change roles.
drop policy if exists "Read own profile or admin" on public.profiles;
create policy "Read own profile or admin" on public.profiles for select to authenticated
using (id = auth.uid() or public.is_admin());
drop policy if exists "Admins manage profiles" on public.profiles;
create policy "Admins manage profiles" on public.profiles for all to authenticated
using (public.is_admin()) with check (public.is_admin());

-- Members see only their own applications. Organizers may see/update all applications.
drop policy if exists "Read own registrations or admin" on public.registrations;
create policy "Read own registrations or admin" on public.registrations for select to authenticated
using (user_id = auth.uid() or public.is_admin());
drop policy if exists "Submit own registration" on public.registrations;
create policy "Submit own registration" on public.registrations for insert to authenticated
with check (user_id = auth.uid() and status = 'Pending' and exists (
  select 1 from public.events e where e.id = event_id and e.status = 'Open'
));
drop policy if exists "Admins update registrations" on public.registrations;
create policy "Admins update registrations" on public.registrations for update to authenticated
using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Admins delete registrations" on public.registrations;
create policy "Admins delete registrations" on public.registrations for delete to authenticated
using (public.is_admin());

-- After creating your organizer account through login.html and confirming its email,
-- replace the email below with that exact account email and run this statement separately:
-- update public.profiles p set role = 'admin'
-- where p.id = (select u.id from auth.users u where lower(u.email) = lower('organizer@example.com'));
