-- Signage Studio schema. Public content is readable by the TV player;
-- authenticated team roles govern screen, playlist, and media access.

create extension if not exists pgcrypto;

create table if not exists public.playlists (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.media_library (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('text', 'image', 'video', 'feed', 'web', 'clock')),
  title text not null check (char_length(title) between 1 and 120),
  body text not null default '',
  source_url text,
  duration_seconds integer not null default 30 check (duration_seconds between 5 and 600),
  refresh_interval_seconds integer not null default 30,
  tags text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists media_library_title_idx on public.media_library using gin (to_tsvector('simple', title));
create index if not exists media_library_tags_idx on public.media_library using gin (tags);
alter table public.media_library add column if not exists refresh_interval_seconds integer not null default 30;
alter table public.media_library drop constraint if exists media_library_refresh_interval_check;
alter table public.media_library add constraint media_library_refresh_interval_check check (refresh_interval_seconds between 10 and 3600);

create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 80),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.team_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null check (role in ('admin', 'editor', 'viewer', 'group_member')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.team_members(user_id, email, role)
select id, email, 'admin' from auth.users where email is not null
on conflict (user_id) do nothing;

create table if not exists public.screens (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 48),
  pair_code text unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  last_seen_at timestamptz,
  preview_updated_at timestamptz,
  current_slide_id uuid,
  current_title text not null default 'Väntar på innehåll',
  current_body text not null default '',
  current_kind text,
  current_source_url text,
  forced_slide_id uuid,
  playlist_id uuid references public.playlists(id) on delete set null,
  group_id uuid
);

create table if not exists public.screen_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 64),
  description text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.screens add column if not exists group_id uuid;
alter table public.screens add column if not exists preview_updated_at timestamptz;
alter table public.screens drop constraint if exists screens_group_id_fkey;
alter table public.screens add constraint screens_group_id_fkey
  foreign key (group_id) references public.screen_groups(id) on delete set null;
create index if not exists screens_group_idx on public.screens(group_id, created_at desc);
create unique index if not exists screen_groups_name_ci_idx on public.screen_groups(lower(btrim(name)));

create table if not exists public.screen_group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.screen_groups(id) on delete cascade,
  user_id uuid not null references public.team_members(user_id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (group_id, user_id)
);
create index if not exists screen_group_members_user_idx on public.screen_group_members(user_id, group_id);

create table if not exists public.screen_channel_schedules (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  channel_id uuid not null references public.channels(id) on delete cascade,
  priority integer not null default 100 check (priority between 0 and 1000),
  active_from timestamptz,
  active_until timestamptz,
  weekdays smallint[],
  daily_start_time time,
  daily_end_time time,
  created_at timestamptz not null default now(),
  unique (screen_id, channel_id),
  check (active_from is null or active_until is null or active_from < active_until),
  check (weekdays is null or (cardinality(weekdays) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[])),
  check ((daily_start_time is null) = (daily_end_time is null))
);

create table if not exists public.channel_playlists (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels(id) on delete cascade,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  sort_order integer not null default 0,
  priority integer not null default 100 check (priority between 0 and 1000),
  active_from timestamptz,
  active_until timestamptz,
  weekdays smallint[],
  daily_start_time time,
  daily_end_time time,
  created_at timestamptz not null default now(),
  unique (channel_id, playlist_id),
  check (active_from is null or active_until is null or active_from < active_until),
  check (weekdays is null or (cardinality(weekdays) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[])),
  check ((daily_start_time is null) = (daily_end_time is null))
);
insert into public.channel_playlists(channel_id, playlist_id)
select id, playlist_id from public.channels
on conflict (channel_id, playlist_id) do nothing;
create index if not exists channel_playlists_priority_idx on public.channel_playlists(channel_id, priority);

create or replace function public.add_default_channel_playlist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.channel_playlists(channel_id, playlist_id)
  values (new.id, new.playlist_id)
  on conflict (channel_id, playlist_id) do nothing;
  return new;
end;
$$;
revoke all on function public.add_default_channel_playlist() from public;
drop trigger if exists add_default_channel_playlist on public.channels;
create trigger add_default_channel_playlist after insert on public.channels
  for each row execute function public.add_default_channel_playlist();

create table if not exists public.slides (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid references public.screens(id) on delete set null,
  playlist_id uuid references public.playlists(id) on delete cascade,
  kind text not null check (kind in ('text', 'image', 'video', 'clock', 'feed', 'web')),
  title text not null default '',
  body text not null default '',
  source_url text,
  library_asset_id uuid references public.media_library(id) on delete set null,
  duration_seconds integer not null default 15 check (duration_seconds between 5 and 600),
  refresh_interval_seconds integer not null default 30,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  active_from timestamptz,
  active_until timestamptz,
  weekdays smallint[],
  daily_start_time time,
  daily_end_time time,
  created_at timestamptz not null default now(),
  constraint slides_content_owner_check check ((screen_id is null) <> (playlist_id is null))
);
alter table public.slides add column if not exists refresh_interval_seconds integer not null default 30;
alter table public.slides drop constraint if exists slides_refresh_interval_check;
alter table public.slides add constraint slides_refresh_interval_check check (refresh_interval_seconds between 10 and 3600);

create index if not exists slides_library_asset_idx on public.slides(library_asset_id) where library_asset_id is not null;
create or replace function public.sync_media_library_references()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.slides
  set kind = new.kind, title = new.title, body = new.body, source_url = new.source_url,
      refresh_interval_seconds = new.refresh_interval_seconds
  where library_asset_id = new.id;
  return new;
end;
$$;
revoke all on function public.sync_media_library_references() from public;
drop trigger if exists sync_media_library_references on public.media_library;
create trigger sync_media_library_references
  after update of kind, title, body, source_url, refresh_interval_seconds on public.media_library
  for each row execute function public.sync_media_library_references();

-- Upgrade existing installations in place.
alter table public.screens add column if not exists last_seen_at timestamptz;
alter table public.screens add column if not exists current_slide_id uuid;
alter table public.screens add column if not exists current_title text not null default 'Väntar på innehåll';
alter table public.screens add column if not exists current_body text not null default '';
alter table public.screens add column if not exists current_kind text;
alter table public.screens add column if not exists current_source_url text;
alter table public.screens add column if not exists forced_slide_id uuid;
alter table public.screens add column if not exists playlist_id uuid references public.playlists(id) on delete set null;
alter table public.slides add column if not exists playlist_id uuid references public.playlists(id) on delete cascade;
alter table public.slides add column if not exists weekdays smallint[];
alter table public.slides add column if not exists daily_start_time time;
alter table public.slides add column if not exists daily_end_time time;
alter table public.slides alter column screen_id drop not null;
alter table public.slides drop constraint if exists slides_weekdays_check;
alter table public.slides add constraint slides_weekdays_check check (weekdays is null or (cardinality(weekdays) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[]));
alter table public.slides drop constraint if exists slides_daily_window_check;
alter table public.slides add constraint slides_daily_window_check check ((daily_start_time is null) = (daily_end_time is null));

do $$
declare
  screen_row record;
  new_playlist_id uuid;
begin
  for screen_row in select id, name from public.screens where playlist_id is null loop
    insert into public.playlists(name) values (screen_row.name || ' – spellista')
      returning id into new_playlist_id;
    update public.slides set playlist_id = new_playlist_id, screen_id = null
      where screen_id = screen_row.id;
    update public.screens set playlist_id = new_playlist_id where id = screen_row.id;
  end loop;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'slides_content_owner_check'
      and conrelid = 'public.slides'::regclass
  ) then
    alter table public.slides add constraint slides_content_owner_check
      check ((screen_id is null) <> (playlist_id is null));
  end if;
end;
$$;
alter table public.slides drop constraint if exists slides_kind_check;
alter table public.slides add constraint slides_kind_check check (kind in ('text', 'image', 'video', 'clock', 'feed', 'web'));
alter table public.screens drop constraint if exists screens_forced_slide_id_fkey;
alter table public.screens add constraint screens_forced_slide_id_fkey
  foreign key (forced_slide_id) references public.slides(id) on delete set null;
alter table public.screens drop constraint if exists screens_current_slide_id_fkey;
alter table public.screens add constraint screens_current_slide_id_fkey
  foreign key (current_slide_id) references public.slides(id) on delete set null;

create index if not exists slides_screen_order_idx on public.slides(screen_id, sort_order);
create index if not exists screens_playlist_idx on public.screens(playlist_id);
create index if not exists slides_playlist_order_idx on public.slides(playlist_id, sort_order, created_at);
create index if not exists slides_schedule_idx on public.slides(active_from, active_until);

grant select, insert, update, delete on public.screens, public.slides, public.playlists to authenticated;
grant select on public.team_members to authenticated;

create or replace function public.current_team_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.team_members where user_id = auth.uid();
$$;
revoke all on function public.current_team_role() from public;
grant execute on function public.current_team_role() to authenticated;

create or replace function public.team_has_role(allowed_roles text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_team_role() = any(allowed_roles), false);
$$;
revoke all on function public.team_has_role(text[]) from public;
grant execute on function public.team_has_role(text[]) to authenticated;

create or replace function public.user_can_access_group(input_group_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.screen_group_members sgm join public.team_members tm on tm.user_id = sgm.user_id
    where sgm.group_id = input_group_id and sgm.user_id = auth.uid() and tm.role = 'group_member');
$$;
create or replace function public.user_can_access_screen(input_screen_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.screens sc where sc.id = input_screen_id and public.user_can_access_group(sc.group_id));
$$;
create or replace function public.user_can_access_channel(input_channel_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.screen_channel_schedules scs join public.screens sc on sc.id = scs.screen_id
    where scs.channel_id = input_channel_id and public.user_can_access_group(sc.group_id));
$$;
create or replace function public.user_can_access_playlist(input_playlist_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.screens sc where sc.playlist_id = input_playlist_id and public.user_can_access_group(sc.group_id))
  or exists (select 1 from public.slides sl join public.screens sc on sc.id = sl.screen_id where sl.playlist_id = input_playlist_id and public.user_can_access_group(sc.group_id))
  or exists (select 1 from public.channel_playlists cp join public.screen_channel_schedules scs on scs.channel_id = cp.channel_id
    join public.screens sc on sc.id = scs.screen_id where cp.playlist_id = input_playlist_id and public.user_can_access_group(sc.group_id));
$$;
create or replace function public.user_can_access_slide(input_slide_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.slides sl where sl.id = input_slide_id and (
    (sl.screen_id is not null and public.user_can_access_screen(sl.screen_id))
    or (sl.playlist_id is not null and public.user_can_access_playlist(sl.playlist_id))));
$$;
create or replace function public.user_can_access_media_asset(input_asset_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.slides sl where sl.library_asset_id = input_asset_id and public.user_can_access_slide(sl.id));
$$;
revoke all on function public.user_can_access_group(uuid) from public;
revoke all on function public.user_can_access_screen(uuid) from public;
revoke all on function public.user_can_access_channel(uuid) from public;
revoke all on function public.user_can_access_playlist(uuid) from public;
revoke all on function public.user_can_access_slide(uuid) from public;
revoke all on function public.user_can_access_media_asset(uuid) from public;
grant execute on function public.user_can_access_group(uuid), public.user_can_access_screen(uuid), public.user_can_access_channel(uuid), public.user_can_access_playlist(uuid), public.user_can_access_slide(uuid), public.user_can_access_media_asset(uuid) to authenticated;

create or replace function public.set_team_member(input_email text, input_role text)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  target_user_id uuid;
  target_email text;
  admin_count integer;
begin
  if public.current_team_role() is distinct from 'admin' then
    raise exception 'Only a team admin can change member roles' using errcode = '42501';
  end if;
  if input_role not in ('admin', 'editor', 'viewer', 'group_member') then
    raise exception 'Role must be admin, editor, viewer, or group_member';
  end if;
  select id, email into target_user_id, target_email
    from auth.users where lower(email) = lower(trim(input_email)) limit 1;
  if target_user_id is null then
    raise exception 'Invite this email in Supabase Auth before assigning a team role';
  end if;
  if target_user_id = auth.uid() and input_role <> 'admin' then
    select count(*) into admin_count from public.team_members where role = 'admin';
    if admin_count <= 1 then
      raise exception 'The last admin cannot remove their own admin role';
    end if;
  end if;
  if input_role <> 'group_member' then
    delete from public.screen_group_members where user_id = target_user_id;
  end if;
  insert into public.team_members(user_id, email, role)
    values (target_user_id, target_email, input_role)
  on conflict (user_id) do update
    set email = excluded.email, role = excluded.role, updated_at = now();
end;
$$;
revoke all on function public.set_team_member(text, text) from public;
grant execute on function public.set_team_member(text, text) to authenticated;

create or replace function public.remove_team_member(input_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  admin_count integer;
  target_role text;
begin
  if public.current_team_role() is distinct from 'admin' then
    raise exception 'Only a team admin can remove a team member' using errcode = '42501';
  end if;
  select role into target_role from public.team_members where user_id = input_user_id;
  if target_role = 'admin' then
    select count(*) into admin_count from public.team_members where role = 'admin';
    if admin_count <= 1 then
      raise exception 'The last admin cannot be removed';
    end if;
  end if;
  delete from public.team_members where user_id = input_user_id;
end;
$$;
revoke all on function public.remove_team_member(uuid) from public;
grant execute on function public.remove_team_member(uuid) to authenticated;

alter table public.team_members enable row level security;
drop policy if exists "Members can read team roster" on public.team_members;
create policy "Members can read team roster" on public.team_members
  for select to authenticated
  using (user_id = auth.uid() or public.team_has_role(array['admin']));
alter table public.screens enable row level security;
alter table public.slides enable row level security;
alter table public.playlists enable row level security;
alter table public.media_library enable row level security;
alter table public.screen_group_members enable row level security;
grant select, insert, update, delete on public.screen_group_members to authenticated;
drop policy if exists "Admins manage screen group members" on public.screen_group_members;
create policy "Admins manage screen group members" on public.screen_group_members
  for all to authenticated using (public.team_has_role(array['admin'])) with check (public.team_has_role(array['admin']));
drop policy if exists "Members read own group access" on public.screen_group_members;
create policy "Members read own group access" on public.screen_group_members for select to authenticated using (user_id = auth.uid());
grant select, insert, update, delete on public.media_library to authenticated;
drop policy if exists "Team can read media library" on public.media_library;
create policy "Team can read media library" on public.media_library
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_media_asset(id));
drop policy if exists "Editors manage media library" on public.media_library;
create policy "Editors manage media library" on public.media_library
  for all to authenticated
  using (public.team_has_role(array['admin','editor']))
  with check (public.team_has_role(array['admin','editor']));

drop policy if exists "Admins manage screens" on public.screens;
drop policy if exists "Team members read screens" on public.screens;
drop policy if exists "Admins insert screens" on public.screens;
drop policy if exists "Admins update screens" on public.screens;
drop policy if exists "Admins delete screens" on public.screens;
create policy "Team members read screens" on public.screens
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_screen(id));
create policy "Admins insert screens" on public.screens
  for insert to authenticated with check (public.team_has_role(array['admin']));
create policy "Admins update screens" on public.screens
  for update to authenticated using (public.team_has_role(array['admin'])) with check (public.team_has_role(array['admin']));
create policy "Admins delete screens" on public.screens
  for delete to authenticated using (public.team_has_role(array['admin']));

alter table public.screen_groups enable row level security;
grant select, insert, update, delete on public.screen_groups to authenticated;
drop policy if exists "Team members read screen groups" on public.screen_groups;
create policy "Team members read screen groups" on public.screen_groups
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_group(id));
drop policy if exists "Admins manage screen groups" on public.screen_groups;
create policy "Admins manage screen groups" on public.screen_groups
  for all to authenticated
  using (public.team_has_role(array['admin']))
  with check (public.team_has_role(array['admin']));

drop policy if exists "Admins manage signage content" on public.slides;
drop policy if exists "Team members read signage content" on public.slides;
drop policy if exists "Editors insert signage content" on public.slides;
drop policy if exists "Editors update signage content" on public.slides;
drop policy if exists "Editors delete signage content" on public.slides;
create policy "Team members read signage content" on public.slides
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_slide(id));
create policy "Editors insert signage content" on public.slides
  for insert to authenticated with check (public.team_has_role(array['admin','editor']));
create policy "Editors update signage content" on public.slides
  for update to authenticated using (public.team_has_role(array['admin','editor'])) with check (public.team_has_role(array['admin','editor']));
create policy "Editors delete signage content" on public.slides
  for delete to authenticated using (public.team_has_role(array['admin','editor']));

drop policy if exists "Admins manage playlists" on public.playlists;
drop policy if exists "Team members read playlists" on public.playlists;
drop policy if exists "Editors insert playlists" on public.playlists;
drop policy if exists "Editors update playlists" on public.playlists;
drop policy if exists "Editors delete playlists" on public.playlists;
create policy "Team members read playlists" on public.playlists
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_playlist(id));
create policy "Editors insert playlists" on public.playlists
  for insert to authenticated with check (public.team_has_role(array['admin','editor']));
create policy "Editors update playlists" on public.playlists
  for update to authenticated using (public.team_has_role(array['admin','editor'])) with check (public.team_has_role(array['admin','editor']));
create policy "Editors delete playlists" on public.playlists
  for delete to authenticated using (public.team_has_role(array['admin','editor']));

-- Narrow remote content control for admins and editors. This does not grant
-- general UPDATE access to screen/device records.
create or replace function public.set_screen_forced_slide(input_screen_id uuid, input_slide_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_playlist_id uuid;
begin
  if public.current_team_role() is distinct from 'admin'
     and public.current_team_role() is distinct from 'editor' then
    raise exception 'Only admins and editors can control screen content' using errcode = '42501';
  end if;
  select playlist_id into target_playlist_id
    from public.screens where id = input_screen_id and is_active = true for update;
  if not found then
    raise exception 'Screen was not found or is paused';
  end if;
  if input_slide_id is not null and not exists (
    select 1 from public.slides sl
    where sl.id = input_slide_id and sl.is_active = true
      and (sl.playlist_id = target_playlist_id or (target_playlist_id is null and sl.screen_id = input_screen_id))
  ) then
    raise exception 'The selected item is not active on this screen';
  end if;
  update public.screens set forced_slide_id = input_slide_id where id = input_screen_id;
end;
$$;
revoke all on function public.set_screen_forced_slide(uuid, uuid) from public;
grant execute on function public.set_screen_forced_slide(uuid, uuid) to authenticated;

grant select, insert, update, delete on public.channels, public.screen_channel_schedules to authenticated;
alter table public.channels enable row level security;
alter table public.screen_channel_schedules enable row level security;
alter table public.channel_playlists enable row level security;
grant select, insert, update, delete on public.channel_playlists to authenticated;
drop policy if exists "Team members read channels" on public.channels;
create policy "Team members read channels" on public.channels for select to authenticated using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_channel(id));
drop policy if exists "Editors insert channels" on public.channels;
create policy "Editors insert channels" on public.channels for insert to authenticated with check (public.team_has_role(array['admin','editor']));
drop policy if exists "Editors update channels" on public.channels;
create policy "Editors update channels" on public.channels for update to authenticated using (public.team_has_role(array['admin','editor'])) with check (public.team_has_role(array['admin','editor']));
drop policy if exists "Editors delete channels" on public.channels;
create policy "Editors delete channels" on public.channels for delete to authenticated using (public.team_has_role(array['admin','editor']));
drop policy if exists "Team members read channel playlists" on public.channel_playlists;
create policy "Team members read channel playlists" on public.channel_playlists for select to authenticated using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_channel(channel_id));
drop policy if exists "Editors manage channel playlists" on public.channel_playlists;
create policy "Editors manage channel playlists" on public.channel_playlists for all to authenticated using (public.team_has_role(array['admin','editor'])) with check (public.team_has_role(array['admin','editor']));
drop policy if exists "Team members read channel schedules" on public.screen_channel_schedules;
create policy "Team members read channel schedules" on public.screen_channel_schedules for select to authenticated using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_screen(screen_id));
drop policy if exists "Editors insert channel schedules" on public.screen_channel_schedules;
create policy "Editors insert channel schedules" on public.screen_channel_schedules for insert to authenticated with check (public.team_has_role(array['admin','editor']));
drop policy if exists "Editors update channel schedules" on public.screen_channel_schedules;
create policy "Editors update channel schedules" on public.screen_channel_schedules for update to authenticated using (public.team_has_role(array['admin','editor'])) with check (public.team_has_role(array['admin','editor']));
drop policy if exists "Editors delete channel schedules" on public.screen_channel_schedules;
create policy "Editors delete channel schedules" on public.screen_channel_schedules for delete to authenticated using (public.team_has_role(array['admin','editor']));
create index if not exists screen_channel_schedule_screen_idx on public.screen_channel_schedules(screen_id, priority);
create index if not exists screen_channel_schedule_channel_idx on public.screen_channel_schedules(channel_id);

-- One-time six-character TV activation code. The TV stores the returned UUID
-- locally; the code is cleared after the first successful claim.
create or replace function public.activate_screen(input_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  claimed_id uuid;
begin
  select id into claimed_id
  from public.screens
  where pair_code = upper(trim(input_code)) and is_active = true
  for update;

  if claimed_id is not null then
    update public.screens
      set pair_code = null, activated_at = now()
      where id = claimed_id;
  end if;

  return claimed_id;
end;
$$;

revoke all on function public.activate_screen(text) from public;
grant execute on function public.activate_screen(text) to anon, authenticated;

-- The player only receives content for its own unguessable screen UUID.
-- A paused screen returns an empty playlist. The TV can call this without login.
create or replace function public.player_playlist(input_screen_id uuid)
returns setof public.slides
language sql
stable
security definer
set search_path = public
as $$
  select sl.*
  from public.slides sl
  join public.screens sc on sc.id = input_screen_id
  where sc.is_active = true and sl.is_active = true
    and (sl.playlist_id = sc.playlist_id or (sc.playlist_id is null and sl.screen_id = sc.id))
    and (sc.forced_slide_id is null or sl.id = sc.forced_slide_id)
  order by sl.sort_order asc, sl.created_at asc;
$$;

revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

-- The native player reports its heartbeat and currently rendered item. A screen
-- UUID is the player's credential; it can only update its own screen record.
create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screens sc
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where sc.id = input_screen_id
    and (input_current_slide_id is null or exists (
      select 1 from public.slides sl
      where sl.id = input_current_slide_id
        and (sl.playlist_id = sc.playlist_id or (sc.playlist_id is null and sl.screen_id = sc.id))
    ));
$$;

revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

-- Public bucket: signage media is intentionally visible on the TV.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('signage-assets', 'signage-assets', true, 419430400,
  array['image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime','application/vnd.apple.mpegurl','application/x-mpegURL'])
on conflict (id) do update set public = true, file_size_limit = 419430400,
  allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('signage-previews', 'signage-previews', false, 2097152, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 2097152,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Team can read live screen previews" on storage.objects;
create policy "Team can read live screen previews" on storage.objects
  for select to authenticated using (
    bucket_id = 'signage-previews'
    and case
      when name ~ '^screens/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/current\.jpg$'
      then public.team_has_role(array['admin','editor','viewer'])
        or public.user_can_access_screen(split_part(name, '/', 2)::uuid)
      else false
    end
  );

drop policy if exists "Public can read signage videos" on storage.objects;
create policy "Public can read signage videos" on storage.objects
  for select to anon, authenticated using (bucket_id = 'signage-assets');

drop policy if exists "Admins upload signage videos" on storage.objects;
create policy "Admins upload signage videos" on storage.objects
  for insert to authenticated with check (bucket_id = 'signage-assets' and public.team_has_role(array['admin','editor']));

drop policy if exists "Admins update signage videos" on storage.objects;
create policy "Admins update signage videos" on storage.objects
  for update to authenticated using (bucket_id = 'signage-assets' and public.team_has_role(array['admin','editor'])) with check (bucket_id = 'signage-assets' and public.team_has_role(array['admin','editor']));

drop policy if exists "Admins delete signage videos" on storage.objects;
create policy "Admins delete signage videos" on storage.objects
  for delete to authenticated using (bucket_id = 'signage-assets' and public.team_has_role(array['admin','editor']));

-- Channel-aware player RPCs (kept in sync with 20261020_channels.sql).
-- Extend direct content control so it can target content in any assigned channel.
create or replace function public.set_screen_forced_slide(input_screen_id uuid, input_slide_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_playlist_id uuid;
begin
  if public.current_team_role() is distinct from 'admin'
     and public.current_team_role() is distinct from 'editor' then
    raise exception 'Only admins and editors can control screen content' using errcode = '42501';
  end if;
  select playlist_id into target_playlist_id
    from public.screens where id = input_screen_id and is_active = true for update;
  if not found then
    raise exception 'Screen was not found or is paused';
  end if;
  if input_slide_id is not null and not exists (
    select 1 from public.slides sl
    where sl.id = input_slide_id and sl.is_active = true
      and (
        sl.playlist_id = target_playlist_id
        or (target_playlist_id is null and sl.screen_id = input_screen_id)
        or exists (
          select 1 from public.screen_channel_schedules scs
          join public.channels ch on ch.id = scs.channel_id
          where scs.screen_id = input_screen_id and sl.playlist_id = ch.playlist_id
        )
      )
  ) then
    raise exception 'The selected item is not active on this screen';
  end if;
  update public.screens set forced_slide_id = input_slide_id where id = input_screen_id;
end;
$$;
revoke all on function public.set_screen_forced_slide(uuid, uuid) from public;
grant execute on function public.set_screen_forced_slide(uuid, uuid) to authenticated;

-- Return complete JSON player items with channel schedule metadata. The player
-- selects the active channel locally, including while its network is offline.
drop function if exists public.player_playlist(uuid);
create function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with target_screen as (
    select id, playlist_id, forced_slide_id, is_active
    from public.screens where id = input_screen_id
  ),
  player_items as (
    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', null::uuid,
        'channel_priority', 2147483647,
        'forced', ts.forced_slide_id = sl.id
      ) as item
    from target_screen ts
    join public.slides sl on
      (sl.playlist_id = ts.playlist_id or (ts.playlist_id is null and sl.screen_id = ts.id))
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_slide_id = sl.id)

    union all

    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', ch.id,
        'channel_name', ch.name,
        'channel_priority', scs.priority,
        'channel_active_from', scs.active_from,
        'channel_active_until', scs.active_until,
        'channel_weekdays', scs.weekdays,
        'channel_daily_start_time', scs.daily_start_time,
        'channel_daily_end_time', scs.daily_end_time,
        'forced', ts.forced_slide_id = sl.id
      ) as item
    from target_screen ts
    join public.screen_channel_schedules scs on scs.screen_id = ts.id
    join public.channels ch on ch.id = scs.channel_id
    join public.slides sl on sl.playlist_id = ch.playlist_id
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_slide_id = sl.id)
  )
  select item from player_items
  order by (item->>'channel_priority')::integer, sort_order, created_at;
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

-- A heartbeat may refer to any item from the screen's fallback playlist or an
-- assigned channel, while still rejecting items from unrelated screens.
create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screens sc
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where sc.id = input_screen_id
    and (input_current_slide_id is null or exists (
      select 1 from public.slides sl
      where sl.id = input_current_slide_id
        and (
          sl.playlist_id = sc.playlist_id
          or (sc.playlist_id is null and sl.screen_id = sc.id)
          or exists (
            select 1 from public.screen_channel_schedules scs
            join public.channels ch on ch.id = scs.channel_id
            where scs.screen_id = sc.id and sl.playlist_id = ch.playlist_id
          )
        )
    ));
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;
-- Simple native multi-zone screen layouts: one primary zone plus an optional
-- live ticker or side panel. The player receives settings with its cached items.
begin;

alter table public.screens
  add column if not exists layout_type text not null default 'single',
  add column if not exists layout_text text not null default '';

alter table public.screens drop constraint if exists screens_layout_type_check;
alter table public.screens add constraint screens_layout_type_check
  check (layout_type in ('single', 'bottom_ticker', 'side_panel'));
alter table public.screens drop constraint if exists screens_layout_text_check;
alter table public.screens add constraint screens_layout_text_check
  check (char_length(layout_text) <= 500);

create or replace function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with target_screen as (
    select id, playlist_id, forced_slide_id, is_active, layout_type, layout_text
    from public.screens where id = input_screen_id
  ),
  player_items as (
    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', null::uuid,
        'channel_priority', 2147483647,
        'forced', ts.forced_slide_id = sl.id,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.slides sl on
      (sl.playlist_id = ts.playlist_id or (ts.playlist_id is null and sl.screen_id = ts.id))
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_slide_id = sl.id)

    union all

    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', ch.id,
        'channel_name', ch.name,
        'channel_priority', scs.priority,
        'channel_active_from', scs.active_from,
        'channel_active_until', scs.active_until,
        'channel_weekdays', scs.weekdays,
        'channel_daily_start_time', scs.daily_start_time,
        'channel_daily_end_time', scs.daily_end_time,
        'forced', ts.forced_slide_id = sl.id,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.screen_channel_schedules scs on scs.screen_id = ts.id
    join public.channels ch on ch.id = scs.channel_id
    join public.slides sl on sl.playlist_id = ch.playlist_id
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_slide_id = sl.id)
  )
  select item from player_items
  order by (item->>'channel_priority')::integer, sort_order, created_at;
$$;

revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;


-- Remote native-player operations.

create table if not exists public.screen_commands (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  command text not null check (command in ('sync_now', 'restart_player')),
  status text not null default 'pending' check (status in ('pending', 'running', 'completed', 'failed')),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  error_message text
);

create index if not exists screen_commands_pending_idx
  on public.screen_commands(screen_id, created_at) where status in ('pending', 'running');

alter table public.screen_commands enable row level security;
revoke all on public.screen_commands from anon, authenticated;
grant select on public.screen_commands to authenticated;

drop policy if exists "Team can read screen command history" on public.screen_commands;
create policy "Team can read screen command history" on public.screen_commands
  for select to authenticated
  using (public.team_has_role(array['admin', 'editor', 'viewer']) or public.user_can_access_screen(screen_id));

create or replace function public.queue_player_command(input_screen_id uuid, input_command text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  command_id uuid;
begin
  if public.current_team_role() is distinct from 'admin'
     and public.current_team_role() is distinct from 'editor' then
    raise exception 'Only admins and editors can operate players' using errcode = '42501';
  end if;
  if input_command not in ('sync_now', 'restart_player') then
    raise exception 'Unsupported player command';
  end if;
  if not exists (select 1 from public.screens where id = input_screen_id and is_active = true) then
    raise exception 'Screen was not found or is paused';
  end if;

  insert into public.screen_commands(screen_id, command)
  values (input_screen_id, input_command)
  returning id into command_id;
  return command_id;
end;
$$;
revoke all on function public.queue_player_command(uuid, text) from public;
grant execute on function public.queue_player_command(uuid, text) to authenticated;

create or replace function public.player_claim_command(input_screen_id uuid)
returns table(command_id uuid, command text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.screens where id = input_screen_id and is_active = true) then
    return;
  end if;

  -- Requeue commands whose player disappeared after claiming them.
  update public.screen_commands
  set status = 'pending', started_at = null
  where screen_id = input_screen_id and status = 'running'
    and started_at < now() - interval '2 minutes';

  return query
  with candidate as (
    select sc.id
    from public.screen_commands sc
    where sc.screen_id = input_screen_id and sc.status = 'pending'
    order by sc.created_at, sc.id
    for update skip locked
    limit 1
  )
  update public.screen_commands sc
  set status = 'running', started_at = now()
  from candidate
  where sc.id = candidate.id
  returning sc.id, sc.command;
end;
$$;
revoke all on function public.player_claim_command(uuid) from public;
grant execute on function public.player_claim_command(uuid) to anon, authenticated;

create or replace function public.player_complete_command(
  input_screen_id uuid,
  input_command_id uuid,
  input_error text default null
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screen_commands
  set status = case when nullif(input_error, '') is null then 'completed' else 'failed' end,
      completed_at = now(),
      error_message = left(nullif(input_error, ''), 500)
  where id = input_command_id and screen_id = input_screen_id and status = 'running';
$$;
revoke all on function public.player_complete_command(uuid, uuid, text) from public;
grant execute on function public.player_complete_command(uuid, uuid, text) to anon, authenticated;

commit;

-- Keep the standalone schema aligned with incremental channel and casting migrations.
alter table public.screens add column if not exists forced_until timestamptz;

create or replace function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with target_screen as (
    select id, playlist_id, forced_slide_id, forced_until, is_active, layout_type, layout_text
    from public.screens where id = input_screen_id
  ),
  player_items as (
    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', null::uuid,
        'channel_priority', 2147483647,
        'channel_playlist_priority', 2147483647,
        'channel_playlist_order', 0,
        'forced', ts.forced_slide_id = sl.id and (ts.forced_until is null or ts.forced_until > now()),
        'forced_until', ts.forced_until,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.slides sl on
      (sl.playlist_id = ts.playlist_id or (ts.playlist_id is null and sl.screen_id = ts.id))
    where ts.is_active and sl.is_active

    union all

    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', ch.id,
        'channel_name', ch.name,
        'channel_priority', scs.priority,
        'channel_active_from', scs.active_from,
        'channel_active_until', scs.active_until,
        'channel_weekdays', scs.weekdays,
        'channel_daily_start_time', scs.daily_start_time,
        'channel_daily_end_time', scs.daily_end_time,
        'channel_playlist_id', cp.playlist_id,
        'channel_playlist_priority', cp.priority,
        'channel_playlist_order', cp.sort_order,
        'channel_playlist_active_from', cp.active_from,
        'channel_playlist_active_until', cp.active_until,
        'channel_playlist_weekdays', cp.weekdays,
        'channel_playlist_daily_start_time', cp.daily_start_time,
        'channel_playlist_daily_end_time', cp.daily_end_time,
        'forced', ts.forced_slide_id = sl.id and (ts.forced_until is null or ts.forced_until > now()),
        'forced_until', ts.forced_until,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.screen_channel_schedules scs on scs.screen_id = ts.id
    join public.channels ch on ch.id = scs.channel_id
    join public.channel_playlists cp on cp.channel_id = ch.id
    join public.slides sl on sl.playlist_id = cp.playlist_id
    where ts.is_active and sl.is_active
  )
  select item from player_items
  order by (item->>'channel_priority')::integer,
           (item->>'channel_playlist_priority')::integer,
           (item->>'channel_playlist_order')::integer,
           sort_order, created_at;
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screens sc
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where sc.id = input_screen_id
    and (input_current_slide_id is null or exists (
      select 1 from public.slides sl
      where sl.id = input_current_slide_id
        and (
          sl.playlist_id = sc.playlist_id
          or (sc.playlist_id is null and sl.screen_id = sc.id)
          or exists (
            select 1 from public.screen_channel_schedules scs
            join public.channels ch on ch.id = scs.channel_id
            join public.channel_playlists cp on cp.channel_id = ch.id
            where scs.screen_id = sc.id and sl.playlist_id = cp.playlist_id
          )
        )
    ));
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

create or replace function public.set_screen_cast(
  input_screen_id uuid,
  input_slide_id uuid,
  input_duration_minutes integer default 10
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_playlist_id uuid;
begin
  if public.current_team_role() is distinct from 'admin'
     and public.current_team_role() is distinct from 'editor' then
    raise exception 'Only admins and editors can control screen content' using errcode = '42501';
  end if;
  if input_duration_minutes not between 1 and 1440 then
    raise exception 'Cast duration must be between 1 and 1440 minutes';
  end if;
  select playlist_id into target_playlist_id
  from public.screens where id = input_screen_id and is_active = true for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;
  if input_slide_id is not null and not exists (
    select 1 from public.slides sl
    where sl.id = input_slide_id and sl.is_active = true
      and (
        sl.playlist_id = target_playlist_id
        or (target_playlist_id is null and sl.screen_id = input_screen_id)
        or exists (
          select 1 from public.screen_channel_schedules scs
          join public.channels ch on ch.id = scs.channel_id
          join public.channel_playlists cp on cp.channel_id = ch.id
          where scs.screen_id = input_screen_id and sl.playlist_id = cp.playlist_id
        )
      )
  ) then raise exception 'The selected item is not active on this screen'; end if;
  update public.screens
  set forced_slide_id = input_slide_id,
      forced_until = case when input_slide_id is null then null else now() + make_interval(mins => input_duration_minutes) end
  where id = input_screen_id;
end;
$$;
revoke all on function public.set_screen_cast(uuid, uuid, integer) from public;
grant execute on function public.set_screen_cast(uuid, uuid, integer) to authenticated;
-- A screen may run its own playlist in the secondary ticker/side-panel zone.
-- Both playlists are sent to the player together for offline schedule selection.
begin;

alter table public.screens
  add column if not exists zone_playlist_id uuid references public.playlists(id) on delete set null;

create index if not exists screens_zone_playlist_idx on public.screens(zone_playlist_id)
  where zone_playlist_id is not null;

create or replace function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with target_screen as (
    select id, playlist_id, zone_playlist_id, forced_slide_id, forced_until,
           is_active, layout_type, layout_text
    from public.screens where id = input_screen_id
  ),
  player_items as (
    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', null::uuid,
        'channel_priority', 2147483647,
        'channel_playlist_priority', 2147483647,
        'channel_playlist_order', 0,
        'forced', ts.forced_slide_id = sl.id and (ts.forced_until is null or ts.forced_until > now()),
        'forced_until', ts.forced_until,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.slides sl on
      (sl.playlist_id = ts.playlist_id or (ts.playlist_id is null and sl.screen_id = ts.id))
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_until <= now() or ts.forced_slide_id = sl.id)

    union all

    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', ch.id,
        'channel_name', ch.name,
        'channel_priority', scs.priority,
        'channel_active_from', scs.active_from,
        'channel_active_until', scs.active_until,
        'channel_weekdays', scs.weekdays,
        'channel_daily_start_time', scs.daily_start_time,
        'channel_daily_end_time', scs.daily_end_time,
        'channel_playlist_id', cp.playlist_id,
        'channel_playlist_priority', cp.priority,
        'channel_playlist_order', cp.sort_order,
        'channel_playlist_active_from', cp.active_from,
        'channel_playlist_active_until', cp.active_until,
        'channel_playlist_weekdays', cp.weekdays,
        'channel_playlist_daily_start_time', cp.daily_start_time,
        'channel_playlist_daily_end_time', cp.daily_end_time,
        'forced', ts.forced_slide_id = sl.id and (ts.forced_until is null or ts.forced_until > now()),
        'forced_until', ts.forced_until,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.screen_channel_schedules scs on scs.screen_id = ts.id
    join public.channels ch on ch.id = scs.channel_id
    join public.channel_playlists cp on cp.channel_id = ch.id
    join public.slides sl on sl.playlist_id = cp.playlist_id
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_until <= now() or ts.forced_slide_id = sl.id)

    union all

    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'layout_zone', 'secondary',
        'channel_id', null::uuid,
        'channel_priority', 2147483646,
        'channel_playlist_priority', 2147483647,
        'channel_playlist_order', 0,
        'forced', false,
        'forced_until', null,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.slides sl on sl.playlist_id = ts.zone_playlist_id
    where ts.is_active and sl.is_active
  )
  select item from player_items
  order by (item->>'channel_priority')::integer,
           (item->>'channel_playlist_priority')::integer,
           (item->>'channel_playlist_order')::integer,
           sort_order, created_at;
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screens sc
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where sc.id = input_screen_id
    and (input_current_slide_id is null or exists (
      select 1 from public.slides sl
      where sl.id = input_current_slide_id
        and (
          sl.playlist_id = sc.playlist_id
          or sl.playlist_id = sc.zone_playlist_id
          or (sc.playlist_id is null and sl.screen_id = sc.id)
          or exists (
            select 1 from public.screen_channel_schedules scs
            join public.channels ch on ch.id = scs.channel_id
            join public.channel_playlists cp on cp.channel_id = ch.id
            where scs.screen_id = sc.id and sl.playlist_id = cp.playlist_id
          )
        )
    ));
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

commit;
-- Re-pair a reset player with its existing screen profile instead of creating
-- a second screen record with a new one-time activation code.
begin;

create or replace function public.renew_screen_pairing_code(input_screen_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
begin
  if public.current_team_role() is distinct from 'admin' then
    raise exception 'Only admins can renew a screen pairing code' using errcode = '42501';
  end if;
  if not exists (select 1 from public.screens where id = input_screen_id and is_active) then
    raise exception 'Screen was not found or is paused';
  end if;

  for attempt_no in 1..20 loop
    candidate := '';
    for char_idx in 1..6 loop
      candidate := candidate || substr(alphabet, (get_byte(gen_random_bytes(1), 0) % length(alphabet)) + 1, 1);
    end loop;
    if exists (select 1 from public.screens where pair_code = candidate) then
      continue;
    end if;
    begin
      update public.screens set pair_code = candidate where id = input_screen_id and is_active;
      if found then return candidate; end if;
    exception when unique_violation then
      -- Another admin generated this code at the same time; choose a new one.
      null;
    end;
  end loop;
  raise exception 'Could not generate a unique pairing code. Try again.';
end;
$$;
revoke all on function public.renew_screen_pairing_code(uuid) from public;
grant execute on function public.renew_screen_pairing_code(uuid) to authenticated;

commit;
-- Recurring screen operating hours. The player remains connected and reports
-- heartbeat while blanking the display outside the configured hours.
begin;

alter table public.screens
  add column if not exists operating_weekdays smallint[],
  add column if not exists operating_start_time time,
  add column if not exists operating_end_time time;

do $$ begin
  alter table public.screens add constraint screens_operating_weekdays_check
    check (operating_weekdays is null or (cardinality(operating_weekdays) between 1 and 7 and operating_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.screens add constraint screens_operating_hours_pair_check
    check ((operating_start_time is null) = (operating_end_time is null));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.screens add constraint screens_operating_hours_unequal_check
    check (operating_start_time is null or operating_start_time <> operating_end_time);
exception when duplicate_object then null;
end $$;

create or replace function public.player_screen_config(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'operating_weekdays', to_jsonb(sc.operating_weekdays),
    'operating_start_time', sc.operating_start_time,
    'operating_end_time', sc.operating_end_time
  )
  from public.screens sc
  where sc.id = input_screen_id and sc.is_active;
$$;
revoke all on function public.player_screen_config(uuid) from public;
grant execute on function public.player_screen_config(uuid) to anon, authenticated;

commit;
-- Align playback timelines across screens that share the same active channel
-- or playlist. Independent remains the default for existing installations.
begin;

alter table public.screens
  add column if not exists playback_mode text not null default 'independent';

do $$ begin
  alter table public.screens add constraint screens_playback_mode_check
    check (playback_mode in ('independent', 'sync'));
exception when duplicate_object then null;
end $$;

create or replace function public.player_screen_config(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'operating_weekdays', to_jsonb(sc.operating_weekdays),
    'operating_start_time', sc.operating_start_time,
    'operating_end_time', sc.operating_end_time,
    'playback_mode', sc.playback_mode
  )
  from public.screens sc
  where sc.id = input_screen_id and sc.is_active;
$$;
revoke all on function public.player_screen_config(uuid) from public;
grant execute on function public.player_screen_config(uuid) to anon, authenticated;

commit;
-- Relaunch the signage player after a TV reboot by default, with an admin
-- control to disable boot launch for an individual screen.
begin;

alter table public.screens
  add column if not exists autostart_enabled boolean not null default true;

create or replace function public.player_screen_config(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'operating_weekdays', to_jsonb(sc.operating_weekdays),
    'operating_start_time', sc.operating_start_time,
    'operating_end_time', sc.operating_end_time,
    'playback_mode', sc.playback_mode,
    'autostart_enabled', sc.autostart_enabled,
    'is_active', sc.is_active
  )
  from public.screens sc
  where sc.id = input_screen_id;
$$;
revoke all on function public.player_screen_config(uuid) from public;
grant execute on function public.player_screen_config(uuid) to anon, authenticated;

commit;

-- Audit history for administration, content, schedules, and player commands.
-- Server-side audit history for important user-facing control-plane changes.
begin;

create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id) on delete set null,
  actor_email text not null,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  entity_type text not null,
  entity_id text not null,
  entity_label text not null,
  changed_fields text[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists activity_log_created_idx on public.activity_log(created_at desc, id desc);
create index if not exists activity_log_entity_idx on public.activity_log(entity_type, created_at desc);

alter table public.activity_log enable row level security;
revoke all on public.activity_log from anon, authenticated;
grant select on public.activity_log to authenticated;
drop policy if exists "Admins read activity log" on public.activity_log;
create policy "Admins read activity log" on public.activity_log
  for select to authenticated using (public.team_has_role(array['admin']));

create or replace function public.capture_activity_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_row jsonb := '{}'::jsonb;
  new_row jsonb := '{}'::jsonb;
  row_data jsonb;
  actor uuid := auth.uid();
  actor_name text;
  row_id text;
  row_label text;
  fields text[] := '{}';
begin
  if tg_op <> 'INSERT' then old_row := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then new_row := to_jsonb(new); end if;
  row_data := case when tg_op = 'DELETE' then old_row else new_row end;
  row_id := coalesce(row_data ->> 'id', row_data ->> 'user_id', 'unknown');
  row_label := coalesce(
    nullif(new_row ->> 'name', ''), nullif(old_row ->> 'name', ''),
    nullif(new_row ->> 'title', ''), nullif(old_row ->> 'title', ''),
    nullif(new_row ->> 'email', ''), nullif(old_row ->> 'email', ''),
    nullif(new_row ->> 'command', ''), left(row_id, 8)
  );

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(n.key order by n.key), '{}') into fields
      from jsonb_each(new_row) as n(key, value)
      where old_row -> n.key is distinct from n.value
        and n.key <> 'updated_at';
    if cardinality(fields) = 0 then return new; end if;
  end if;

  if actor is not null then
    select tm.email into actor_name from public.team_members tm where tm.user_id = actor;
  end if;

  insert into public.activity_log(actor_id, actor_email, action, entity_type, entity_id, entity_label, changed_fields)
  values (actor, coalesce(actor_name, 'System/automatiserat'), tg_op, tg_table_name, row_id, row_label, fields);

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.capture_activity_log() from public, anon, authenticated;

-- Track only administrative columns on screens; TV heartbeats update current_* and last_seen_at.
drop trigger if exists activity_screens_insert_delete on public.screens;
create trigger activity_screens_insert_delete after insert or delete on public.screens
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_screens_update on public.screens;
create trigger activity_screens_update after update of name, is_active, group_id, playlist_id,
  forced_slide_id, forced_until, zone_playlist_id, layout_type, layout_text,
  operating_weekdays, operating_start_time, operating_end_time, playback_mode, autostart_enabled
  on public.screens for each row execute function public.capture_activity_log();

drop trigger if exists activity_slides_insert_delete on public.slides;
create trigger activity_slides_insert_delete after insert or delete on public.slides
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_slides_update on public.slides;
create trigger activity_slides_update after update of screen_id, playlist_id, kind, title, body, source_url,
  library_asset_id, duration_seconds, refresh_interval_seconds, sort_order, is_active,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.slides for each row execute function public.capture_activity_log();

drop trigger if exists activity_playlists_insert_delete on public.playlists;
create trigger activity_playlists_insert_delete after insert or delete on public.playlists
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_playlists_update on public.playlists;
create trigger activity_playlists_update after update of name on public.playlists
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_media_library_insert_delete on public.media_library;
create trigger activity_media_library_insert_delete after insert or delete on public.media_library
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_media_library_update on public.media_library;
create trigger activity_media_library_update after update of kind, title, body, source_url,
  duration_seconds, refresh_interval_seconds, tags on public.media_library
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_channels_insert_delete on public.channels;
create trigger activity_channels_insert_delete after insert or delete on public.channels
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_channels_update on public.channels;
create trigger activity_channels_update after update of name, playlist_id on public.channels
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_channel_playlists_insert_delete on public.channel_playlists;
create trigger activity_channel_playlists_insert_delete after insert or delete on public.channel_playlists
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_channel_playlists_update on public.channel_playlists;
create trigger activity_channel_playlists_update after update of channel_id, playlist_id, sort_order, priority,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.channel_playlists for each row execute function public.capture_activity_log();

drop trigger if exists activity_screen_schedules_insert_delete on public.screen_channel_schedules;
create trigger activity_screen_schedules_insert_delete after insert or delete on public.screen_channel_schedules
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_screen_schedules_update on public.screen_channel_schedules;
create trigger activity_screen_schedules_update after update of screen_id, channel_id, priority,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.screen_channel_schedules for each row execute function public.capture_activity_log();

drop trigger if exists activity_screen_groups_insert_delete on public.screen_groups;
create trigger activity_screen_groups_insert_delete after insert or delete on public.screen_groups
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_screen_groups_update on public.screen_groups;
create trigger activity_screen_groups_update after update of name, description on public.screen_groups
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_group_members_insert_delete on public.screen_group_members;
create trigger activity_group_members_insert_delete after insert or delete on public.screen_group_members
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_team_members_insert_delete on public.team_members;
create trigger activity_team_members_insert_delete after insert or delete on public.team_members
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_team_members_update on public.team_members;
create trigger activity_team_members_update after update of email, role on public.team_members
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_screen_commands_insert on public.screen_commands;
create trigger activity_screen_commands_insert after insert on public.screen_commands
  for each row execute function public.capture_activity_log();

commit;
