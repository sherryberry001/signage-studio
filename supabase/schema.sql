-- Signage Studio schema. Public content is readable by the TV player;
-- authenticated team roles govern screen, playlist, and media access.

create extension if not exists pgcrypto;
create extension if not exists pg_cron with schema pg_catalog;

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
  expires_at timestamptz,
  tags text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists media_library_title_idx on public.media_library using gin (to_tsvector('simple', title));
create index if not exists media_library_tags_idx on public.media_library using gin (tags);
alter table public.media_library add column if not exists refresh_interval_seconds integer not null default 30;
alter table public.media_library add column if not exists expires_at timestamptz;
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
  device_identity text,
  preview_updated_at timestamptz,
  current_slide_id uuid,
  current_title text not null default 'Väntar på innehåll',
  current_body text not null default '',
  current_kind text,
  current_source_url text,
  forced_slide_id uuid,
  playlist_id uuid references public.playlists(id) on delete set null,
  group_id uuid,
  playback_mode text not null default 'independent'
);

create table if not exists public.screen_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 64),
  description text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.screens add column if not exists group_id uuid;
alter table public.screens add column if not exists device_identity text;
alter table public.screens add column if not exists preview_updated_at timestamptz;
alter table public.screens add column if not exists playback_mode text not null default 'independent';
alter table public.screens drop constraint if exists screens_playback_mode_check;
alter table public.screens add constraint screens_playback_mode_check
  check (playback_mode in ('independent', 'sync', 'random'));
alter table public.screens drop constraint if exists screens_group_id_fkey;
alter table public.screens add constraint screens_group_id_fkey
  foreign key (group_id) references public.screen_groups(id) on delete set null;
create index if not exists screens_group_idx on public.screens(group_id, created_at desc);
create unique index if not exists screen_groups_name_ci_idx on public.screen_groups(lower(btrim(name)));
create unique index if not exists screens_name_ci_active_idx
  on public.screens(lower(btrim(name))) where is_active = true;
create unique index if not exists screens_device_identity_active_idx
  on public.screens(device_identity) where is_active = true and device_identity is not null;

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
  expires_at timestamptz,
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
alter table public.slides add column if not exists expires_at timestamptz;
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
      refresh_interval_seconds = new.refresh_interval_seconds, expires_at = new.expires_at
  where library_asset_id = new.id;
  return new;
end;
$$;
revoke all on function public.sync_media_library_references() from public;
drop trigger if exists sync_media_library_references on public.media_library;
create trigger sync_media_library_references
  after update of kind, title, body, source_url, refresh_interval_seconds, expires_at on public.media_library
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

create or replace function public.activate_screen(input_code text, input_device_identity text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.screens%rowtype;
  existing_id uuid;
begin
  if input_device_identity is null or input_device_identity !~ '^device:[a-f0-9]{64}$' then
    raise exception 'Invalid player identity';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(input_device_identity, 0));

  select * into target
  from public.screens
  where pair_code = upper(trim(input_code)) and is_active = true
  for update;
  if not found then return null; end if;

  select id into existing_id
  from public.screens
  where device_identity = input_device_identity and is_active = true
  for update;

  if existing_id is not null and existing_id <> target.id then
    if target.activated_at is null
       and target.playlist_id is null
       and target.forced_slide_id is null
       and not exists (select 1 from public.slides where screen_id = target.id)
       and not exists (select 1 from public.screen_channel_schedules where screen_id = target.id) then
      update public.screens set is_active = false, pair_code = null where id = target.id;
      return existing_id;
    end if;
    raise exception 'This TV is already paired to another screen profile';
  end if;
  if target.device_identity is not null and target.device_identity <> input_device_identity then
    raise exception 'This screen profile belongs to another TV';
  end if;

  update public.screens
  set pair_code = null,
      activated_at = coalesce(activated_at, now()),
      device_identity = input_device_identity
  where id = target.id;
  return target.id;
end;
$$;
revoke all on function public.activate_screen(text, text) from public;
grant execute on function public.activate_screen(text, text) to anon, authenticated;

create or replace function public.player_bind_device_identity(input_screen_id uuid, input_device_identity text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_identity text;
  existing_id uuid;
begin
  if input_device_identity is null or input_device_identity !~ '^device:[a-f0-9]{64}$' then
    raise exception 'Invalid player identity';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(input_device_identity, 0));

  select device_identity into target_identity
  from public.screens
  where id = input_screen_id and is_active = true
  for update;
  if not found then return null; end if;

  select id into existing_id
  from public.screens
  where device_identity = input_device_identity and is_active = true
  for update;
  if existing_id is not null and existing_id <> input_screen_id then
    raise exception 'This TV is already paired to another screen profile';
  end if;
  if target_identity is not null and target_identity <> input_device_identity then
    raise exception 'This screen profile belongs to another TV';
  end if;

  update public.screens set device_identity = input_device_identity where id = input_screen_id;
  return input_screen_id;
end;
$$;
revoke all on function public.player_bind_device_identity(uuid, text) from public;
grant execute on function public.player_bind_device_identity(uuid, text) to anon, authenticated;

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
  where (item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now())
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
  where (item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now())
  order by (item->>'channel_priority')::integer, sort_order, created_at;
$$;

revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;


-- Remote native-player operations.

create table if not exists public.screen_commands (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  command text not null check (command in ('sync_now', 'restart_player', 'capture_preview')),
  status text not null default 'pending' check (status in ('pending', 'running', 'completed', 'failed')),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  error_message text
);

create index if not exists screen_commands_pending_idx
  on public.screen_commands(screen_id, created_at) where status in ('pending', 'running');
create unique index if not exists screen_commands_one_pending_per_type_idx
  on public.screen_commands(screen_id, command) where status = 'pending';

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
  if input_command not in ('sync_now', 'restart_player', 'capture_preview') then
    raise exception 'Unsupported player command';
  end if;
  if not exists (select 1 from public.screens where id = input_screen_id and is_active = true) then
    raise exception 'Screen was not found or is paused';
  end if;

  insert into public.screen_commands(screen_id, command)
  values (input_screen_id, input_command)
  on conflict (screen_id, command) where status = 'pending'
  do update set command = excluded.command
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

-- Retain the content transitions reported by each active player for playback
-- history. Names and titles are snapshotted so reports remain useful later.
create table if not exists public.playback_events (
  id bigint generated always as identity primary key,
  screen_id uuid references public.screens(id) on delete set null,
  screen_name text not null,
  screen_group_id uuid references public.screen_groups(id) on delete set null,
  slide_id uuid,
  content_title text not null,
  content_kind text,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);
create index if not exists playback_events_started_idx on public.playback_events(started_at desc, id desc);
create index if not exists playback_events_screen_idx on public.playback_events(screen_id, started_at desc);
create index if not exists playback_events_content_idx on public.playback_events(content_title, started_at desc);
alter table public.playback_events enable row level security;
revoke all on public.playback_events from anon, authenticated;
grant select on public.playback_events to authenticated;
drop policy if exists "Team can read playback history" on public.playback_events;
create policy "Team can read playback history" on public.playback_events
  for select to authenticated
  using (
    public.team_has_role(array['admin', 'editor', 'viewer'])
    or (screen_id is not null and public.user_can_access_screen(screen_id))
    or (screen_group_id is not null and public.user_can_access_group(screen_group_id))
  );

create or replace function public.capture_playback_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.current_slide_id is not distinct from new.current_slide_id then
    return new;
  end if;
  update public.playback_events set ended_at = now()
    where screen_id = new.id and ended_at is null;
  if new.current_slide_id is not null and new.is_active and new.activated_at is not null then
    insert into public.playback_events(
      screen_id, screen_name, screen_group_id, slide_id, content_title, content_kind
    ) values (
      new.id, new.name, new.group_id, new.current_slide_id,
      coalesce(nullif(new.current_title, ''), 'Innehåll'), new.current_kind
    );
  end if;
  return new;
end;
$$;
revoke all on function public.capture_playback_transition() from public, anon, authenticated;
drop trigger if exists capture_playback_transition on public.screens;
create trigger capture_playback_transition after update of current_slide_id on public.screens
  for each row execute function public.capture_playback_transition();

-- Player diagnostics support fleet compatibility and troubleshooting.
alter table public.screens
  add column if not exists player_version text,
  add column if not exists device_model text,
  add column if not exists android_version text,
  add column if not exists display_size text,
  add column if not exists network_type text,
  add column if not exists device_updated_at timestamptz;
create or replace function public.player_report_device_info(
  input_screen_id uuid,
  input_player_version text,
  input_device_model text,
  input_android_version text,
  input_display_size text,
  input_network_type text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screens
  set player_version = left(nullif(input_player_version, ''), 40),
      device_model = left(nullif(input_device_model, ''), 100),
      android_version = left(nullif(input_android_version, ''), 40),
      display_size = left(nullif(input_display_size, ''), 40),
      network_type = left(nullif(input_network_type, ''), 24),
      device_updated_at = now()
  where id = input_screen_id and is_active and activated_at is not null;
$$;
revoke all on function public.player_report_device_info(uuid, text, text, text, text, text) from public;
grant execute on function public.player_report_device_info(uuid, text, text, text, text, text) to anon, authenticated;

-- A narrow, player-only feed health report. Team-visible data never includes
-- credentials or the source URL's query/fragment.
create table if not exists public.screen_feed_status (
  screen_id uuid not null references public.screens(id) on delete cascade,
  slide_id uuid not null references public.slides(id) on delete cascade,
  screen_name text not null,
  screen_group_id uuid references public.screen_groups(id) on delete set null,
  feed_title text not null,
  source_host text not null default '',
  status text not null check (status in ('ok', 'http_error', 'network_error', 'invalid_json')),
  last_attempt_at timestamptz not null default now(),
  last_success_at timestamptz,
  last_http_status integer,
  last_error_code text,
  primary key (screen_id, slide_id)
);
create index if not exists screen_feed_status_attempt_idx on public.screen_feed_status(last_attempt_at desc);
create index if not exists screen_feed_status_group_idx on public.screen_feed_status(screen_group_id, last_attempt_at desc);
alter table public.screen_feed_status enable row level security;
revoke all on public.screen_feed_status from anon, authenticated;
grant select on public.screen_feed_status to authenticated;
drop policy if exists "Team can read live feed health" on public.screen_feed_status;
create policy "Team can read live feed health" on public.screen_feed_status
  for select to authenticated
  using (
    public.team_has_role(array['admin', 'editor', 'viewer'])
    or public.user_can_access_screen(screen_id)
    or (screen_group_id is not null and public.user_can_access_group(screen_group_id))
  );

create or replace function public.player_report_feed_status(
  input_screen_id uuid,
  input_slide_id uuid,
  input_status text,
  input_http_status integer default null,
  input_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  screen_row public.screens%rowtype;
  slide_row public.slides%rowtype;
  host_value text;
begin
  if input_status not in ('ok', 'http_error', 'network_error', 'invalid_json') then
    raise exception 'Unsupported feed status';
  end if;
  select * into screen_row from public.screens
    where id = input_screen_id and is_active and activated_at is not null;
  if not found then return; end if;
  select * into slide_row from public.slides sl
    where sl.id = input_slide_id and sl.kind = 'feed'
      and (
        sl.playlist_id = screen_row.playlist_id
        or sl.playlist_id = screen_row.zone_playlist_id
        or (sl.playlist_id is null and sl.screen_id = screen_row.id)
        or exists (
          select 1 from public.screen_channel_schedules scs
          join public.channels ch on ch.id = scs.channel_id
          join public.channel_playlists cp on cp.channel_id = ch.id
          where scs.screen_id = screen_row.id and cp.playlist_id = sl.playlist_id
        )
      );
  if not found then return; end if;
  host_value := regexp_replace(
    split_part(split_part(coalesce(slide_row.source_url, ''), '://', 2), '/', 1), '[?#].*$', ''
  );
  insert into public.screen_feed_status(
    screen_id, slide_id, screen_name, screen_group_id, feed_title, source_host,
    status, last_attempt_at, last_success_at, last_http_status, last_error_code
  ) values (
    screen_row.id, slide_row.id, screen_row.name, screen_row.group_id,
    coalesce(nullif(slide_row.title, ''), 'Live-feed'), host_value,
    input_status, now(), case when input_status = 'ok' then now() else null end,
    input_http_status, left(nullif(input_error_code, ''), 40)
  )
  on conflict (screen_id, slide_id) do update set
    screen_name = excluded.screen_name,
    screen_group_id = excluded.screen_group_id,
    feed_title = excluded.feed_title,
    source_host = excluded.source_host,
    status = excluded.status,
    last_attempt_at = excluded.last_attempt_at,
    last_success_at = case when excluded.status = 'ok'
      then excluded.last_success_at else public.screen_feed_status.last_success_at end,
    last_http_status = excluded.last_http_status,
    last_error_code = excluded.last_error_code;
end;
$$;
revoke all on function public.player_report_feed_status(uuid, uuid, text, integer, text) from public;
grant execute on function public.player_report_feed_status(uuid, uuid, text, integer, text) to anon, authenticated;

-- Establish the current relational player query as the internal draft source.
drop function if exists public.player_playlist_source(uuid);
alter function public.player_playlist(uuid) rename to player_playlist_source;
revoke all on function public.player_playlist_source(uuid) from public, anon, authenticated;

-- Managed live integrations. Credentials are never selectable by the admin client;
-- players receive them only after the RPC validates screen-to-slide assignment.
create table if not exists public.signage_integrations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 100),
  provider text not null check (provider in ('dizparc_pulse')),
  endpoint_url text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (endpoint_url ~ '^https?://[^/?#]+(/[^?#]*)?$'),
  check (split_part(split_part(endpoint_url, '://', 2), '/', 1) !~ '@')
);
create table if not exists public.signage_integration_secrets (
  integration_id uuid primary key references public.signage_integrations(id) on delete cascade,
  display_token text not null check (char_length(display_token) >= 32),
  updated_at timestamptz not null default now()
);
alter table public.signage_integrations enable row level security;
alter table public.signage_integration_secrets enable row level security;
revoke all on public.signage_integrations from public, anon, authenticated;
revoke all on public.signage_integration_secrets from public, anon, authenticated;
alter table public.media_library
  add column if not exists integration_id uuid references public.signage_integrations(id) on delete set null;
alter table public.slides
  add column if not exists integration_id uuid references public.signage_integrations(id) on delete set null;
create index if not exists media_library_integration_idx on public.media_library(integration_id) where integration_id is not null;
create index if not exists slides_integration_idx on public.slides(integration_id) where integration_id is not null;

create or replace function public.sync_media_library_references()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.slides
  set kind = new.kind, title = new.title, body = new.body,
      source_url = new.source_url, integration_id = new.integration_id,
      refresh_interval_seconds = new.refresh_interval_seconds, expires_at = new.expires_at
  where library_asset_id = new.id;
  return new;
end;
$$;
drop trigger if exists sync_media_library_references on public.media_library;
create trigger sync_media_library_references
  after update of kind, title, body, source_url, integration_id, refresh_interval_seconds, expires_at on public.media_library
  for each row execute function public.sync_media_library_references();
drop trigger if exists activity_slides_update on public.slides;
create trigger activity_slides_update after update of screen_id, playlist_id, integration_id, kind, title, body, source_url,
  library_asset_id, duration_seconds, refresh_interval_seconds, expires_at, sort_order, is_active,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.slides for each row execute function public.capture_activity_log();
drop trigger if exists activity_media_library_update on public.media_library;
create trigger activity_media_library_update after update of kind, title, body, source_url,
  integration_id, duration_seconds, refresh_interval_seconds, expires_at, tags on public.media_library
  for each row execute function public.capture_activity_log();

create or replace function public.team_list_signage_integrations()
returns table(id uuid, name text, provider text, endpoint_url text, updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.current_team_role(), '') not in ('admin', 'editor') then
    raise exception 'Only admins and editors can manage integrations' using errcode = '42501';
  end if;
  return query select integration.id, integration.name, integration.provider,
      integration.endpoint_url, integration.updated_at
    from public.signage_integrations integration order by integration.name;
end;
$$;
revoke all on function public.team_list_signage_integrations() from public, anon;
grant execute on function public.team_list_signage_integrations() to authenticated;

create or replace function public.manage_signage_integration(
  input_integration_id uuid, input_name text, input_endpoint_url text, input_display_token text
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  result_id uuid;
  clean_endpoint text := btrim(input_endpoint_url);
  clean_name text := btrim(input_name);
  clean_token text := nullif(btrim(input_display_token), '');
begin
  if public.current_team_role() is distinct from 'admin' then
    raise exception 'Only admins can manage integration credentials' using errcode = '42501';
  end if;
  if char_length(clean_name) not between 1 and 100 then raise exception 'Integration name must be 1 to 100 characters'; end if;
  if clean_endpoint !~ '^https?://[^/?#]+(/[^?#]*)?$'
     or split_part(split_part(clean_endpoint, '://', 2), '/', 1) ~ '@' then
    raise exception 'Use an HTTP(S) endpoint without URL credentials, query parameters, or fragments';
  end if;
  if clean_token is not null and char_length(clean_token) < 32 then raise exception 'Pulse display token must be at least 32 characters'; end if;
  if input_integration_id is null then
    if clean_token is null then raise exception 'Pulse display token is required'; end if;
    insert into public.signage_integrations(name, provider, endpoint_url)
      values (clean_name, 'dizparc_pulse', clean_endpoint) returning id into result_id;
  else
    update public.signage_integrations set name = clean_name, endpoint_url = clean_endpoint, updated_at = now()
      where id = input_integration_id returning id into result_id;
    if result_id is null then raise exception 'Integration was not found'; end if;
    if clean_token is null and not exists (select 1 from public.signage_integration_secrets where integration_id = result_id) then
      raise exception 'Pulse display token is required';
    end if;
  end if;
  if clean_token is not null then
    insert into public.signage_integration_secrets(integration_id, display_token, updated_at)
      values (result_id, clean_token, now())
      on conflict (integration_id) do update set display_token = excluded.display_token, updated_at = excluded.updated_at;
  end if;
  update public.media_library set source_url = clean_endpoint, updated_at = now()
    where integration_id = result_id and source_url is distinct from clean_endpoint;
  update public.slides set source_url = clean_endpoint
    where integration_id = result_id and source_url is distinct from clean_endpoint;
  return result_id;
end;
$$;
revoke all on function public.manage_signage_integration(uuid, text, text, text) from public, anon;
grant execute on function public.manage_signage_integration(uuid, text, text, text) to authenticated;

create or replace function public.player_get_integration_config(input_screen_id uuid, input_slide_id uuid)
returns table(provider text, endpoint_url text, display_token text)
language plpgsql security definer set search_path = public as $$
declare
  screen_row public.screens%rowtype;
  slide_integration_id uuid;
begin
  select * into screen_row from public.screens
    where id = input_screen_id and is_active and activated_at is not null;
  if not found then return; end if;
  select slide.integration_id into slide_integration_id from public.slides slide
    where slide.id = input_slide_id and slide.kind = 'feed' and slide.integration_id is not null
      and (slide.playlist_id = screen_row.playlist_id or slide.playlist_id = screen_row.zone_playlist_id
        or (slide.playlist_id is null and slide.screen_id = screen_row.id)
        or exists (select 1 from public.screen_channel_schedules schedule
          join public.channels channel on channel.id = schedule.channel_id
          join public.channel_playlists membership on membership.channel_id = channel.id
          where schedule.screen_id = screen_row.id and membership.playlist_id = slide.playlist_id));
  if slide_integration_id is null then return; end if;
  return query select integration.provider, integration.endpoint_url, secret.display_token
    from public.signage_integrations integration
    join public.signage_integration_secrets secret on secret.integration_id = integration.id
    where integration.id = slide_integration_id;
end;
$$;
revoke all on function public.player_get_integration_config(uuid, uuid) from public;
grant execute on function public.player_get_integration_config(uuid, uuid) to anon, authenticated;

-- Append-only observed screen availability transitions, detected by Supabase Cron.
create table if not exists public.screen_health_events (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  screen_name text not null,
  screen_group_id uuid references public.screen_groups(id) on delete set null,
  status text not null check (status in ('online', 'offline')),
  observed_at timestamptz not null default now(),
  last_seen_at timestamptz
);
create index if not exists screen_health_events_history_idx
  on public.screen_health_events(screen_id, observed_at desc);
create index if not exists screen_health_events_group_idx
  on public.screen_health_events(screen_group_id, observed_at desc);
alter table public.screen_health_events enable row level security;
revoke all on public.screen_health_events from public, anon, authenticated;
grant select on public.screen_health_events to authenticated;
drop policy if exists "Team can read screen health history" on public.screen_health_events;
create policy "Team can read screen health history" on public.screen_health_events
  for select to authenticated
  using (
    public.team_has_role(array['admin', 'editor', 'viewer'])
    or public.user_can_access_screen(screen_id)
    or (screen_group_id is not null and public.user_can_access_group(screen_group_id))
  );

create or replace function public.record_screen_health_transitions()
returns integer language plpgsql security definer set search_path = public as $$
declare
  screen_row record;
  previous_status text;
  next_status text;
  inserted_count integer := 0;
begin
  for screen_row in
    select id, name, group_id, last_seen_at, activated_at from public.screens
    where is_active and activated_at is not null
  loop
    perform pg_advisory_xact_lock(hashtextextended(screen_row.id::text, 0));
    select event.status into previous_status from public.screen_health_events event
      where event.screen_id = screen_row.id
      order by event.observed_at desc, event.id desc limit 1;
    next_status := case when screen_row.last_seen_at >= now() - interval '45 seconds' then 'online' else 'offline' end;
    if previous_status is distinct from next_status then
      insert into public.screen_health_events(screen_id, screen_name, screen_group_id, status, observed_at, last_seen_at)
        values (screen_row.id, screen_row.name, screen_row.group_id, next_status, now(), screen_row.last_seen_at);
      inserted_count := inserted_count + 1;
    end if;
  end loop;
  return inserted_count;
end;
$$;
revoke all on function public.record_screen_health_transitions() from public, anon, authenticated;
do $$
declare existing_job bigint;
begin
  for existing_job in select jobid from cron.job where jobname = 'signage-screen-health-observer' loop
    perform cron.unschedule(existing_job);
  end loop;
  perform cron.schedule('signage-screen-health-observer', '* * * * *', 'select public.record_screen_health_transitions();');
end;
$$;

create or replace function public.reorder_playlist_slides(input_playlist_id uuid, input_slide_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare
  expected_count integer;
  requested_count integer;
  unique_count integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin', 'editor') then
    raise exception 'Only admins and editors can reorder playlist items' using errcode = '42501';
  end if;
  if input_playlist_id is null or input_slide_ids is null then
    raise exception 'Playlist and ordered slide IDs are required';
  end if;
  perform id from public.playlists where id = input_playlist_id for update;
  if not found then raise exception 'Playlist was not found'; end if;
  select count(*) into expected_count from public.slides where playlist_id = input_playlist_id;
  requested_count := cardinality(input_slide_ids);
  select count(distinct slide_id) into unique_count from unnest(input_slide_ids) as requested(slide_id);
  if requested_count <> expected_count or unique_count <> expected_count then
    raise exception 'The order must contain every playlist item exactly once';
  end if;
  if exists (
    select 1 from unnest(input_slide_ids) as requested(slide_id)
    where not exists (select 1 from public.slides slide
      where slide.id = requested.slide_id and slide.playlist_id = input_playlist_id)
  ) then raise exception 'The order contains an item outside this playlist'; end if;
  update public.slides slide
  set sort_order = ordered.ordinality::integer * 10
  from unnest(input_slide_ids) with ordinality as ordered(slide_id, ordinality)
  where slide.id = ordered.slide_id and slide.playlist_id = input_playlist_id;
end;
$$;
revoke all on function public.reorder_playlist_slides(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_playlist_slides(uuid, uuid[]) to authenticated;

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
  where (item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now())
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
  where (item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now())
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
    check (playback_mode in ('independent', 'sync', 'random'));
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
  library_asset_id, duration_seconds, refresh_interval_seconds, expires_at, sort_order, is_active,
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
  duration_seconds, refresh_interval_seconds, expires_at, tags on public.media_library
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

-- Private per-screen feed health. Source credentials are omitted from reports.
create table if not exists public.screen_feed_status (
  screen_id uuid not null references public.screens(id) on delete cascade,
  slide_id uuid not null references public.slides(id) on delete cascade,
  screen_name text not null,
  screen_group_id uuid references public.screen_groups(id) on delete set null,
  feed_title text not null,
  source_host text not null default '',
  status text not null check (status in ('ok', 'http_error', 'network_error', 'invalid_json')),
  last_attempt_at timestamptz not null default now(),
  last_success_at timestamptz,
  last_http_status integer,
  last_error_code text,
  primary key (screen_id, slide_id)
);
create index if not exists screen_feed_status_attempt_idx on public.screen_feed_status(last_attempt_at desc);
create index if not exists screen_feed_status_group_idx on public.screen_feed_status(screen_group_id, last_attempt_at desc);
alter table public.screen_feed_status enable row level security;
revoke all on public.screen_feed_status from anon, authenticated;
grant select on public.screen_feed_status to authenticated;
drop policy if exists "Team can read live feed health" on public.screen_feed_status;
create policy "Team can read live feed health" on public.screen_feed_status
  for select to authenticated
  using (
    public.team_has_role(array['admin', 'editor', 'viewer'])
    or public.user_can_access_screen(screen_id)
    or (screen_group_id is not null and public.user_can_access_group(screen_group_id))
  );

create or replace function public.player_report_feed_status(
  input_screen_id uuid,
  input_slide_id uuid,
  input_status text,
  input_http_status integer default null,
  input_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  screen_row public.screens%rowtype;
  slide_row public.slides%rowtype;
  host_value text;
begin
  if input_status not in ('ok', 'http_error', 'network_error', 'invalid_json') then
    raise exception 'Unsupported feed status';
  end if;
  select * into screen_row from public.screens
    where id = input_screen_id and is_active and activated_at is not null;
  if not found then return; end if;
  select * into slide_row from public.slides sl
    where sl.id = input_slide_id and sl.kind = 'feed'
      and (
        sl.playlist_id = screen_row.playlist_id
        or sl.playlist_id = screen_row.zone_playlist_id
        or (sl.playlist_id is null and sl.screen_id = screen_row.id)
        or exists (
          select 1 from public.screen_channel_schedules scs
          join public.channels ch on ch.id = scs.channel_id
          join public.channel_playlists cp on cp.channel_id = ch.id
          where scs.screen_id = screen_row.id and cp.playlist_id = sl.playlist_id
        )
      );
  if not found then return; end if;
  if exists (
    select 1 from public.screen_feed_status
    where screen_id = screen_row.id and slide_id = slide_row.id
      and last_attempt_at > now() - interval '5 seconds'
  ) then
    return;
  end if;
  host_value := regexp_replace(
    split_part(split_part(coalesce(slide_row.source_url, ''), '://', 2), '/', 1), '[?#].*$', ''
  );
  insert into public.screen_feed_status(
    screen_id, slide_id, screen_name, screen_group_id, feed_title, source_host,
    status, last_attempt_at, last_success_at, last_http_status, last_error_code
  ) values (
    screen_row.id, slide_row.id, screen_row.name, screen_row.group_id,
    coalesce(nullif(slide_row.title, ''), 'Live-feed'), host_value,
    input_status, now(), case when input_status = 'ok' then now() else null end,
    input_http_status, left(nullif(input_error_code, ''), 40)
  )
  on conflict (screen_id, slide_id) do update set
    screen_name = excluded.screen_name,
    screen_group_id = excluded.screen_group_id,
    feed_title = excluded.feed_title,
    source_host = excluded.source_host,
    status = excluded.status,
    last_attempt_at = excluded.last_attempt_at,
    last_success_at = case when excluded.status = 'ok'
      then excluded.last_success_at else public.screen_feed_status.last_success_at end,
    last_http_status = excluded.last_http_status,
    last_error_code = excluded.last_error_code;
end;
$$;
revoke all on function public.player_report_feed_status(uuid, uuid, text, integer, text) from public;
grant execute on function public.player_report_feed_status(uuid, uuid, text, integer, text) to anon, authenticated;
-- Publish a versioned per-screen content snapshot. Player polling reads only
-- the last published snapshot; edits in the admin tables remain drafts.
begin;

create table if not exists public.screen_publications (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  revision integer not null check (revision >= 0),
  payload jsonb not null check (jsonb_typeof(payload) = 'array'),
  published_at timestamptz not null default now(),
  published_by uuid references auth.users(id) on delete set null,
  unique (screen_id, revision)
);
create index if not exists screen_publications_latest_idx
  on public.screen_publications(screen_id, revision desc);

alter table public.screen_publications enable row level security;
revoke all on public.screen_publications from public, anon, authenticated;
grant select on public.screen_publications to authenticated;
drop policy if exists "Team can read screen publications" on public.screen_publications;
create policy "Team can read screen publications" on public.screen_publications
  for select to authenticated using (
    public.team_has_role(array['admin','editor','viewer'])
    or public.user_can_access_screen(screen_id)
  );

create or replace function public.initialize_screen_publication()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.screen_publications(screen_id, revision, payload, published_at)
  values (new.id, 0, '[]'::jsonb, coalesce(new.activated_at, new.created_at));
  return new;
end;
$$;
revoke all on function public.initialize_screen_publication() from public, anon, authenticated;
drop trigger if exists initialize_screen_publication on public.screens;
create trigger initialize_screen_publication after insert on public.screens
  for each row execute function public.initialize_screen_publication();

-- Existing screens start with exactly the content they were already showing.
insert into public.screen_publications(screen_id, revision, payload, published_at)
select screen_row.id, 0, live.payload, coalesce(screen_row.activated_at, screen_row.created_at)
from public.screens screen_row
cross join lateral (
  select coalesce(jsonb_agg(item order by
    (item->>'channel_priority')::integer,
    (item->>'channel_playlist_priority')::integer,
    (item->>'channel_playlist_order')::integer,
    (item->>'sort_order')::integer,
    (item->>'created_at')::timestamptz
  ), '[]'::jsonb) as payload
  from public.player_playlist_source(screen_row.id) as current_item(item)
  where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now()
) live
on conflict (screen_id, revision) do nothing;

create or replace function public.publish_screen_content(input_screen_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  next_revision integer;
  content_snapshot jsonb;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can publish screen content' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(input_screen_id::text, 71));
  perform 1 from public.screens where id = input_screen_id and is_active = true for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;

  select coalesce(jsonb_agg(
    jsonb_set(jsonb_set(item, '{forced}', 'false'::jsonb, true), '{forced_until}', 'null'::jsonb, true)
    order by (item->>'channel_priority')::integer,
      (item->>'channel_playlist_priority')::integer,
      (item->>'channel_playlist_order')::integer,
      (item->>'sort_order')::integer,
      (item->>'created_at')::timestamptz
  ), '[]'::jsonb)
  into content_snapshot
  from public.player_playlist_source(input_screen_id) as current_item(item)
  where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now();

  select coalesce(max(revision), 0) + 1 into next_revision
  from public.screen_publications where screen_id = input_screen_id;
  insert into public.screen_publications(screen_id, revision, payload, published_by)
  values (input_screen_id, next_revision, content_snapshot, auth.uid());
  insert into public.screen_commands(screen_id, command)
  values (input_screen_id, 'sync_now')
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return next_revision;
end;
$$;
revoke all on function public.publish_screen_content(uuid) from public, anon;
grant execute on function public.publish_screen_content(uuid) to authenticated;

create or replace function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with latest_publication as (
    select publication.payload
    from public.screen_publications publication
    join public.screens screen_row on screen_row.id = publication.screen_id and screen_row.is_active
    where publication.screen_id = input_screen_id
    order by publication.revision desc
    limit 1
  ), player_items as (
    select item, item_position, false as is_forced
    from latest_publication publication
    cross join lateral jsonb_array_elements(publication.payload) with ordinality as snapshot(item, item_position)
    where item->>'expires_at' is null
      or (item->>'expires_at')::timestamptz > now()

    union all

    select item, item_position, true as is_forced
    from public.player_playlist_source(input_screen_id) with ordinality as live(item, item_position)
    where item->>'forced' = 'true'
      and (item->>'forced_until' is null or (item->>'forced_until')::timestamptz > now())
      and (item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now())
  )
  select item from player_items order by is_forced desc, item_position;
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

-- Resolve integration credentials from the published media snapshot, so edits
-- to a feed connection cannot silently change the TV before publication.
create or replace function public.player_get_integration_config(input_screen_id uuid, input_slide_id uuid)
returns table(provider text, endpoint_url text, display_token text)
language plpgsql
security definer
set search_path = public
as $$
declare
  integration_id_value uuid;
begin
  if not exists (select 1 from public.screens where id = input_screen_id and is_active and activated_at is not null) then
    return;
  end if;
  select (candidate.item->>'integration_id')::uuid into integration_id_value
  from (
    select live.item, 1 as source_priority
    from public.player_playlist_source(input_screen_id) as live(item)
    where live.item->>'id' = input_slide_id::text
      and live.item->>'forced' = 'true'
    union all
    select published.item, 2 as source_priority
    from public.screen_publications publication
    cross join lateral jsonb_array_elements(publication.payload) as published(item)
    where publication.screen_id = input_screen_id
      and publication.revision = (select max(current.revision) from public.screen_publications current where current.screen_id = input_screen_id)
      and published.item->>'id' = input_slide_id::text
      and published.item->>'kind' = 'feed'
      and published.item->>'integration_id' is not null
  ) candidate
  where candidate.item->>'kind' = 'feed' and candidate.item->>'integration_id' is not null
  order by candidate.source_priority
  limit 1;
  if integration_id_value is null then return; end if;
  return query select integration.provider, integration.endpoint_url, secret.display_token
  from public.signage_integrations integration
  join public.signage_integration_secrets secret on secret.integration_id = integration.id
  where integration.id = integration_id_value;
end;
$$;
revoke all on function public.player_get_integration_config(uuid, uuid) from public;
grant execute on function public.player_get_integration_config(uuid, uuid) to anon, authenticated;

create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.screens screen_row
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where screen_row.id = input_screen_id
    and screen_row.is_active
    and (input_current_slide_id is null or exists (
      select 1 from public.player_playlist(input_screen_id) published(item)
      where published.item->>'id' = input_current_slide_id::text
    ));
end;
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

create or replace function public.player_report_feed_status(
  input_screen_id uuid,
  input_slide_id uuid,
  input_status text,
  input_http_status integer default null,
  input_error_code text default null
)
returns void language plpgsql security definer set search_path = public as $$
declare
  screen_row public.screens%rowtype;
  feed_title text;
  feed_source_url text;
  host_value text;
begin
  if input_status not in ('ok', 'http_error', 'network_error', 'invalid_json') then
    raise exception 'Unsupported feed status';
  end if;
  select * into screen_row from public.screens
    where id = input_screen_id and is_active and activated_at is not null;
  if not found then return; end if;
  select item->>'title', item->>'source_url' into feed_title, feed_source_url
  from public.player_playlist(input_screen_id) as published(item)
  where item->>'id' = input_slide_id::text and item->>'kind' = 'feed'
  limit 1;
  if not found then return; end if;
  if exists (
    select 1 from public.screen_feed_status
    where screen_id = screen_row.id and slide_id = input_slide_id
      and last_attempt_at > now() - interval '5 seconds'
  ) then return; end if;
  host_value := regexp_replace(
    split_part(split_part(coalesce(feed_source_url, ''), '://', 2), '/', 1), '[?#].*$', ''
  );
  insert into public.screen_feed_status(
    screen_id, slide_id, screen_name, screen_group_id, feed_title, source_host,
    status, last_attempt_at, last_success_at, last_http_status, last_error_code
  ) values (
    screen_row.id, input_slide_id, screen_row.name, screen_row.group_id,
    coalesce(nullif(feed_title, ''), 'Live-feed'), host_value,
    input_status, now(), case when input_status = 'ok' then now() else null end,
    input_http_status, left(nullif(input_error_code, ''), 40)
  )
  on conflict (screen_id, slide_id) do update set
    screen_name = excluded.screen_name,
    screen_group_id = excluded.screen_group_id,
    feed_title = excluded.feed_title,
    source_host = excluded.source_host,
    status = excluded.status,
    last_attempt_at = excluded.last_attempt_at,
    last_success_at = case when excluded.status = 'ok'
      then excluded.last_success_at else public.screen_feed_status.last_success_at end,
    last_http_status = excluded.last_http_status,
    last_error_code = excluded.last_error_code;
end;
$$;
revoke all on function public.player_report_feed_status(uuid, uuid, text, integer, text) from public;
grant execute on function public.player_report_feed_status(uuid, uuid, text, integer, text) to anon, authenticated;

commit;
-- Restore a published screen snapshot as a new revision, preserving history.
begin;

create or replace function public.restore_screen_publication(
  input_screen_id uuid,
  input_revision integer
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  next_revision integer;
  restored_payload jsonb;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can restore screen content' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(input_screen_id::text, 71));
  perform 1 from public.screens where id = input_screen_id and is_active = true for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;

  select payload into restored_payload
  from public.screen_publications
  where screen_id = input_screen_id and revision = input_revision;
  if not found then raise exception 'Publication version was not found'; end if;

  select coalesce(max(revision), 0) + 1 into next_revision
  from public.screen_publications where screen_id = input_screen_id;

  insert into public.screen_publications(screen_id, revision, payload, published_by)
  values (input_screen_id, next_revision, restored_payload, auth.uid());
  insert into public.screen_commands(screen_id, command)
  values (input_screen_id, 'sync_now')
  on conflict (screen_id, command) where status = 'pending' do nothing;

  return next_revision;
end;
$$;
revoke all on function public.restore_screen_publication(uuid, integer) from public, anon;
grant execute on function public.restore_screen_publication(uuid, integer) to authenticated;

commit;
-- Editors submit an immutable draft snapshot; admins approve or reject it.
begin;

create table if not exists public.screen_publication_requests (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  payload jsonb not null check (jsonb_typeof(payload) = 'array'),
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','superseded')),
  requested_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_note text
);
create index if not exists screen_publication_requests_screen_idx
  on public.screen_publication_requests(screen_id, requested_at desc);
create unique index if not exists one_pending_screen_publication_request
  on public.screen_publication_requests(screen_id) where status = 'pending';

alter table public.screen_publication_requests enable row level security;
revoke all on public.screen_publication_requests from public, anon, authenticated;
grant select (id, screen_id, status, requested_by, requested_at, reviewed_by, reviewed_at, review_note)
  on public.screen_publication_requests to authenticated;
drop policy if exists "Admins and request owners can read publication requests"
  on public.screen_publication_requests;
create policy "Admins and request owners can read publication requests"
  on public.screen_publication_requests for select to authenticated
  using (coalesce(public.current_team_role(), '') = 'admin' or requested_by = auth.uid());

create or replace function public.request_screen_publication(input_screen_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  request_id uuid;
  content_snapshot jsonb;
begin
  if coalesce(public.current_team_role(), '') <> 'editor' then
    raise exception 'Only editors can request publication approval' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(input_screen_id::text, 71));
  perform 1 from public.screens where id = input_screen_id and is_active = true for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;

  select coalesce(jsonb_agg(
    jsonb_set(jsonb_set(item, '{forced}', 'false'::jsonb, true), '{forced_until}', 'null'::jsonb, true)
    order by (item->>'channel_priority')::integer,
      (item->>'channel_playlist_priority')::integer,
      (item->>'channel_playlist_order')::integer,
      (item->>'sort_order')::integer,
      (item->>'created_at')::timestamptz
  ), '[]'::jsonb)
  into content_snapshot
  from public.player_playlist_source(input_screen_id) as current_item(item)
  where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now();

  update public.screen_publication_requests
  set status = 'superseded', reviewed_by = auth.uid(), reviewed_at = now(),
      review_note = 'Ersatt av en ny inskickad version.'
  where screen_id = input_screen_id and status = 'pending';

  insert into public.screen_publication_requests(screen_id, payload, requested_by)
  values (input_screen_id, content_snapshot, auth.uid())
  returning id into request_id;
  return request_id;
end;
$$;
revoke all on function public.request_screen_publication(uuid) from public, anon;
grant execute on function public.request_screen_publication(uuid) to authenticated;

create or replace function public.review_screen_publication(
  input_request_id uuid,
  input_decision text,
  input_review_note text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.screen_publication_requests%rowtype;
  next_revision integer;
begin
  if coalesce(public.current_team_role(), '') <> 'admin' then
    raise exception 'Only admins can review publication requests' using errcode = '42501';
  end if;
  if input_decision not in ('approve','reject') then
    raise exception 'Decision must be approve or reject';
  end if;

  select * into request_row from public.screen_publication_requests
  where id = input_request_id and status = 'pending' for update;
  if not found then raise exception 'Pending publication request was not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended(request_row.screen_id::text, 71));
  perform 1 from public.screens where id = request_row.screen_id and is_active = true for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;

  if input_decision = 'reject' then
    update public.screen_publication_requests
    set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
        review_note = left(nullif(trim(input_review_note), ''), 500)
    where id = request_row.id;
    return null;
  end if;

  select coalesce(max(revision), 0) + 1 into next_revision
  from public.screen_publications where screen_id = request_row.screen_id;
  insert into public.screen_publications(screen_id, revision, payload, published_by)
  values (request_row.screen_id, next_revision, request_row.payload, auth.uid());
  insert into public.screen_commands(screen_id, command)
  values (request_row.screen_id, 'sync_now')
  on conflict (screen_id, command) where status = 'pending' do nothing;
  update public.screen_publication_requests
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = null
  where id = request_row.id;
  return next_revision;
end;
$$;
revoke all on function public.review_screen_publication(uuid, text, text) from public, anon;
grant execute on function public.review_screen_publication(uuid, text, text) to authenticated;

commit;

-- Migration: 20261118_locations.sql
-- Locations own screen access; group membership remains a narrower compatible scope.
begin;

create table if not exists public.locations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 80),
  description text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);
create unique index if not exists locations_name_ci_idx on public.locations(lower(btrim(name)));

create table if not exists public.location_members (
  id uuid primary key default gen_random_uuid(),
  location_id uuid not null references public.locations(id) on delete cascade,
  user_id uuid not null references public.team_members(user_id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (location_id, user_id)
);
create index if not exists location_members_user_idx on public.location_members(user_id, location_id);

alter table public.screens add column if not exists location_id uuid;
alter table public.screens drop constraint if exists screens_location_id_fkey;
alter table public.screens add constraint screens_location_id_fkey
  foreign key (location_id) references public.locations(id) on delete restrict;
create index if not exists screens_location_idx on public.screens(location_id, created_at desc);

-- Keep existing screens together in an editable default location. Existing
-- group-member grants stay unchanged until an admin explicitly grants a space.
insert into public.locations(name, description)
values ('Standardplats', 'Plats för befintliga skärmar. Byt namn eller skapa fler platser efter behov.')
on conflict do nothing;
update public.screens
set location_id = (select id from public.locations where lower(name) = lower('Standardplats') limit 1)
where location_id is null;

alter table public.locations enable row level security;
alter table public.location_members enable row level security;
revoke all on public.locations, public.location_members from public, anon, authenticated;
grant select, insert, update, delete on public.locations to authenticated;
grant select, insert, delete on public.location_members to authenticated;

create or replace function public.user_can_access_location(input_location_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.location_members lm
    join public.team_members tm on tm.user_id = lm.user_id
    where lm.location_id = input_location_id
      and lm.user_id = auth.uid()
      and tm.role = 'group_member'
  );
$$;

drop policy if exists "Team and location members read locations" on public.locations;
create policy "Team and location members read locations" on public.locations
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_location(id));
drop policy if exists "Admins manage locations" on public.locations;
create policy "Admins manage locations" on public.locations
  for all to authenticated
  using (public.team_has_role(array['admin']))
  with check (public.team_has_role(array['admin']));
drop policy if exists "Admins manage location members" on public.location_members;
create policy "Admins manage location members" on public.location_members
  for all to authenticated
  using (public.team_has_role(array['admin']))
  with check (
    public.team_has_role(array['admin'])
    and exists (
      select 1 from public.team_members member_row
      where member_row.user_id = location_members.user_id and member_row.role = 'group_member'
    )
  );
drop policy if exists "Members read own location access" on public.location_members;
create policy "Members read own location access" on public.location_members
  for select to authenticated using (user_id = auth.uid());

create or replace function public.user_can_access_group(input_group_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.screen_group_members sgm
    join public.team_members tm on tm.user_id = sgm.user_id
    where sgm.group_id = input_group_id and sgm.user_id = auth.uid() and tm.role = 'group_member'
  ) or exists (
    select 1 from public.screens sc
    where sc.group_id = input_group_id and public.user_can_access_location(sc.location_id)
  );
$$;

create or replace function public.user_can_access_screen(input_screen_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.screens sc
    where sc.id = input_screen_id
      and (
        public.user_can_access_location(sc.location_id)
        or public.user_can_access_group(sc.group_id)
      )
  );
$$;

create or replace function public.user_can_access_channel(input_channel_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.screen_channel_schedules scs
    join public.screens sc on sc.id = scs.screen_id
    where scs.channel_id = input_channel_id and public.user_can_access_screen(sc.id)
  );
$$;

create or replace function public.user_can_access_playlist(input_playlist_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.screens sc
    where sc.playlist_id = input_playlist_id and public.user_can_access_screen(sc.id)
  ) or exists (
    select 1 from public.slides sl
    where sl.playlist_id = input_playlist_id and sl.screen_id is not null
      and public.user_can_access_screen(sl.screen_id)
  ) or exists (
    select 1 from public.channel_playlists cp
    join public.screen_channel_schedules scs on scs.channel_id = cp.channel_id
    where cp.playlist_id = input_playlist_id and public.user_can_access_screen(scs.screen_id)
  );
$$;

revoke all on function public.user_can_access_location(uuid) from public, anon;
revoke all on function public.user_can_access_group(uuid) from public, anon;
revoke all on function public.user_can_access_screen(uuid) from public, anon;
revoke all on function public.user_can_access_channel(uuid) from public, anon;
revoke all on function public.user_can_access_playlist(uuid) from public, anon;
grant execute on function public.user_can_access_location(uuid), public.user_can_access_group(uuid),
  public.user_can_access_screen(uuid), public.user_can_access_channel(uuid), public.user_can_access_playlist(uuid)
  to authenticated;

drop policy if exists "Team members read screen groups" on public.screen_groups;
create policy "Team members read screen groups" on public.screen_groups
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_group(id));
drop policy if exists "Team members read screens" on public.screens;
create policy "Team members read screens" on public.screens
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_screen(id));

drop trigger if exists activity_locations_insert_delete on public.locations;
create trigger activity_locations_insert_delete after insert or delete on public.locations
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_locations_update on public.locations;
create trigger activity_locations_update after update of name, description on public.locations
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_location_members_insert_delete on public.location_members;
create trigger activity_location_members_insert_delete after insert or delete on public.location_members
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_screens_location_update on public.screens;
create trigger activity_screens_location_update after update of location_id on public.screens
  for each row execute function public.capture_activity_log();

commit;

-- Migration: 20261119_publication_ack.sql
-- Let the player atomically read a published revision and acknowledge that it
-- has stored that revision locally. This is delivery evidence, not proof that
-- the physical panel is powered or visible.
begin;

alter table public.screens
  add column if not exists applied_revision integer,
  add column if not exists applied_revision_at timestamptz;

create or replace function public.player_publication_snapshot(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with player_screen as (
    select id from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ), latest_publication as (
    select publication.revision, publication.payload
    from public.screen_publications publication
    join player_screen on player_screen.id = publication.screen_id
    order by publication.revision desc
    limit 1
  ), published_items as (
    select item, item_position, false as is_forced
    from latest_publication publication
    cross join lateral jsonb_array_elements(publication.payload) with ordinality as snapshot(item, item_position)
    where item->>'expires_at' is null
      or (item->>'expires_at')::timestamptz > now()
  ), forced_items as (
    select live.item, live.ordinality as item_position, true as is_forced
    from player_screen
    cross join lateral public.player_playlist_source(player_screen.id) with ordinality as live(item, ordinality)
    where live.item->>'forced' = 'true'
      and (live.item->>'forced_until' is null or (live.item->>'forced_until')::timestamptz > now())
      and (live.item->>'expires_at' is null or (live.item->>'expires_at')::timestamptz > now())
  ), all_items as (
    select * from published_items
    union all
    select * from forced_items
  )
  select jsonb_build_object(
    'revision', latest_publication.revision,
    'items', coalesce((
      select jsonb_agg(all_items.item order by all_items.is_forced desc, all_items.item_position)
      from all_items
    ), '[]'::jsonb)
  )
  from latest_publication
  where exists (select 1 from player_screen);
$$;

create or replace function public.player_ack_screen_publication(
  input_screen_id uuid,
  input_revision integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if input_revision is null or input_revision < 0 then return false; end if;
  if not exists (
    select 1 from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ) then return false; end if;
  if not exists (
    select 1 from public.screen_publications
    where screen_id = input_screen_id and revision = input_revision
  ) then return false; end if;

  update public.screens
  set applied_revision = input_revision,
      applied_revision_at = now()
  where id = input_screen_id
    and (applied_revision is null or applied_revision < input_revision);
  return true;
end;
$$;

revoke all on function public.player_publication_snapshot(uuid) from public;
revoke all on function public.player_ack_screen_publication(uuid, integer) from public;
grant execute on function public.player_publication_snapshot(uuid) to anon, authenticated;
grant execute on function public.player_ack_screen_publication(uuid, integer) to anon, authenticated;

commit;

-- Migration: 20261119_publication_ack.sql
-- Let the player atomically read a published revision and acknowledge that it
-- has stored that revision locally. This is delivery evidence, not proof that
-- the physical panel is powered or visible.
begin;

alter table public.screens
  add column if not exists applied_revision integer,
  add column if not exists applied_revision_at timestamptz;

create or replace function public.player_publication_snapshot(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with player_screen as (
    select id from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ), latest_publication as (
    select publication.revision, publication.payload
    from public.screen_publications publication
    join player_screen on player_screen.id = publication.screen_id
    order by publication.revision desc
    limit 1
  ), published_items as (
    select item, item_position, false as is_forced
    from latest_publication publication
    cross join lateral jsonb_array_elements(publication.payload) with ordinality as snapshot(item, item_position)
    where item->>'expires_at' is null
      or (item->>'expires_at')::timestamptz > now()
  ), forced_items as (
    select live.item, live.ordinality as item_position, true as is_forced
    from player_screen
    cross join lateral public.player_playlist_source(player_screen.id) with ordinality as live(item, ordinality)
    where live.item->>'forced' = 'true'
      and (live.item->>'forced_until' is null or (live.item->>'forced_until')::timestamptz > now())
      and (live.item->>'expires_at' is null or (live.item->>'expires_at')::timestamptz > now())
  ), all_items as (
    select * from published_items
    union all
    select * from forced_items
  )
  select jsonb_build_object(
    'revision', latest_publication.revision,
    'items', coalesce((
      select jsonb_agg(all_items.item order by all_items.is_forced desc, all_items.item_position)
      from all_items
    ), '[]'::jsonb)
  )
  from latest_publication
  where exists (select 1 from player_screen);
$$;

create or replace function public.player_ack_screen_publication(
  input_screen_id uuid,
  input_revision integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if input_revision is null or input_revision < 0 then return false; end if;
  if not exists (
    select 1 from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ) then return false; end if;
  if not exists (
    select 1 from public.screen_publications
    where screen_id = input_screen_id and revision = input_revision
  ) then return false; end if;

  update public.screens
  set applied_revision = input_revision,
      applied_revision_at = now()
  where id = input_screen_id
    and (applied_revision is null or applied_revision < input_revision);
  return true;
end;
$$;

revoke all on function public.player_publication_snapshot(uuid) from public;
revoke all on function public.player_ack_screen_publication(uuid, integer) from public;
grant execute on function public.player_publication_snapshot(uuid) to anon, authenticated;
grant execute on function public.player_ack_screen_publication(uuid, integer) to anon, authenticated;



create table if not exists public.media_folders (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 64),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null
);
create unique index if not exists media_folders_name_ci_idx
  on public.media_folders(lower(btrim(name)));

alter table public.media_library add column if not exists folder_id uuid;
alter table public.media_library drop constraint if exists media_library_folder_id_fkey;
alter table public.media_library add constraint media_library_folder_id_fkey
  foreign key (folder_id) references public.media_folders(id) on delete set null;
create index if not exists media_library_folder_updated_idx
  on public.media_library(folder_id, updated_at desc);

create table if not exists public.media_library_versions (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.media_library(id) on delete cascade,
  version integer not null check (version > 0),
  source_url text not null,
  file_name text not null default '',
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  unique (asset_id, version)
);
create index if not exists media_library_versions_asset_idx
  on public.media_library_versions(asset_id, version desc);

create or replace function public.user_can_access_media_folder(input_folder_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.media_library asset
    where asset.folder_id = input_folder_id
      and public.user_can_access_media_asset(asset.id)
  );
$$;
revoke all on function public.user_can_access_media_folder(uuid) from public, anon;
grant execute on function public.user_can_access_media_folder(uuid) to authenticated;

alter table public.media_folders enable row level security;
revoke all on public.media_folders from public, anon, authenticated;
grant select, insert, update, delete on public.media_folders to authenticated;
drop policy if exists "Team members read media folders" on public.media_folders;
create policy "Team members read media folders" on public.media_folders
  for select to authenticated
  using (
    public.team_has_role(array['admin','editor','viewer'])
    or public.user_can_access_media_folder(id)
  );
drop policy if exists "Editors manage media folders" on public.media_folders;
create policy "Editors manage media folders" on public.media_folders
  for all to authenticated
  using (public.team_has_role(array['admin','editor']))
  with check (public.team_has_role(array['admin','editor']));

alter table public.media_library_versions enable row level security;
revoke all on public.media_library_versions from public, anon, authenticated;
grant select on public.media_library_versions to authenticated;
drop policy if exists "Team members read media file history" on public.media_library_versions;
create policy "Team members read media file history" on public.media_library_versions
  for select to authenticated
  using (
    public.team_has_role(array['admin','editor','viewer'])
    or public.user_can_access_media_asset(asset_id)
  );

-- Preserve the current file as v1 for existing uploaded library items.
insert into public.media_library_versions(asset_id, version, source_url, file_name, created_at)
select asset.id, 1, asset.source_url,
  regexp_replace(split_part(asset.source_url, '?', 1), '^.*/', ''),
  coalesce(asset.updated_at, asset.created_at, now())
from public.media_library asset
where asset.kind in ('image','video')
  and asset.source_url like '%/storage/v1/object/public/signage-assets/%'
  and not exists (
    select 1 from public.media_library_versions history where history.asset_id = asset.id
  )
on conflict (asset_id, version) do nothing;

create or replace function public.record_media_library_file_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  next_version integer;
begin
  if new.kind not in ('image','video')
     or new.source_url is null
     or new.source_url not like '%/storage/v1/object/public/signage-assets/%'
     or (tg_op = 'UPDATE' and old.source_url is not distinct from new.source_url) then
    return new;
  end if;

  select coalesce(max(version), 0) + 1 into next_version
  from public.media_library_versions
  where asset_id = new.id;

  insert into public.media_library_versions(asset_id, version, source_url, file_name, created_by)
  values (
    new.id,
    next_version,
    new.source_url,
    regexp_replace(split_part(new.source_url, '?', 1), '^.*/', ''),
    auth.uid()
  );
  return new;
end;
$$;
revoke all on function public.record_media_library_file_version() from public, anon, authenticated;
drop trigger if exists record_media_library_file_version on public.media_library;
create trigger record_media_library_file_version
  after insert or update of source_url on public.media_library
  for each row execute function public.record_media_library_file_version();

drop trigger if exists activity_media_library_update on public.media_library;
create trigger activity_media_library_update after update of kind, title, body, source_url,
  integration_id, duration_seconds, refresh_interval_seconds, expires_at, tags, folder_id
  on public.media_library for each row execute function public.capture_activity_log();

drop trigger if exists activity_media_folders_change on public.media_folders;
create trigger activity_media_folders_change after insert or update of name or delete on public.media_folders
  for each row execute function public.capture_activity_log();



create or replace function public.duplicate_playlist_with_content(input_playlist_id uuid, input_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_playlist_id uuid;
  target_name text := btrim(coalesce(input_name, ''));
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can duplicate playlists' using errcode = '42501';
  end if;
  if char_length(target_name) not between 1 and 80 then
    raise exception 'Playlist name must be between 1 and 80 characters';
  end if;
  if not exists (select 1 from public.playlists where id = input_playlist_id) then
    raise exception 'Source playlist was not found';
  end if;

  insert into public.playlists(name) values (target_name)
  returning id into new_playlist_id;

  insert into public.slides(
    screen_id, playlist_id, kind, title, body, source_url, library_asset_id,
    integration_id, expires_at, duration_seconds, refresh_interval_seconds,
    sort_order, is_active, active_from, active_until, weekdays,
    daily_start_time, daily_end_time
  )
  select
    null, new_playlist_id, slide.kind, slide.title, slide.body, slide.source_url,
    slide.library_asset_id, slide.integration_id, slide.expires_at,
    slide.duration_seconds, slide.refresh_interval_seconds, slide.sort_order,
    slide.is_active, slide.active_from, slide.active_until, slide.weekdays,
    slide.daily_start_time, slide.daily_end_time
  from public.slides slide
  where slide.playlist_id = input_playlist_id
  order by slide.sort_order, slide.created_at, slide.id;

  return new_playlist_id;
end;
$$;
revoke all on function public.duplicate_playlist_with_content(uuid, text) from public, anon;
grant execute on function public.duplicate_playlist_with_content(uuid, text) to authenticated;

commit;


-- Migration: 20261123_screen_broadcasts.sql
-- Deliver one time-limited announcement to several screens without changing
-- their saved playlists or published revisions.
begin;

create table if not exists public.screen_broadcasts (
  id uuid primary key default gen_random_uuid(),
  slide_id uuid unique,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  body text not null check (char_length(btrim(body)) between 1 and 1200),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  cancelled_at timestamptz,
  check (starts_at < ends_at)
);
alter table public.screen_broadcasts
  add column if not exists slide_id uuid;
alter table public.screen_broadcasts alter column slide_id drop not null;
alter table public.screen_broadcasts drop constraint if exists screen_broadcasts_slide_id_fkey;
create unique index if not exists screen_broadcasts_slide_id_idx
  on public.screen_broadcasts(slide_id) where slide_id is not null;

create table if not exists public.screen_broadcast_targets (
  broadcast_id uuid not null references public.screen_broadcasts(id) on delete cascade,
  screen_id uuid not null references public.screens(id) on delete cascade,
  superseded_at timestamptz,
  primary key (broadcast_id, screen_id)
);
alter table public.screen_broadcast_targets
  add column if not exists superseded_at timestamptz;
alter table public.slides add column if not exists broadcast_id uuid;
alter table public.slides drop constraint if exists slides_content_owner_check;
alter table public.slides add constraint slides_content_owner_check check (
  (screen_id is not null)::integer
  + (playlist_id is not null)::integer
  + (broadcast_id is not null)::integer = 1
);
alter table public.slides drop constraint if exists slides_broadcast_id_fkey;
alter table public.slides add constraint slides_broadcast_id_fkey
  foreign key (broadcast_id) references public.screen_broadcasts(id) on delete cascade;
create index if not exists screen_broadcast_targets_screen_idx
  on public.screen_broadcast_targets(screen_id, broadcast_id);
create index if not exists screen_broadcasts_active_idx
  on public.screen_broadcasts(starts_at, ends_at) where cancelled_at is null;

alter table public.screen_broadcasts enable row level security;
alter table public.screen_broadcast_targets enable row level security;
revoke all on public.screen_broadcasts, public.screen_broadcast_targets from public, anon, authenticated;
grant select on public.screen_broadcasts, public.screen_broadcast_targets to authenticated;

drop policy if exists "Team can read accessible broadcasts" on public.screen_broadcasts;
create policy "Team can read accessible broadcasts" on public.screen_broadcasts
  for select to authenticated using (
    public.team_has_role(array['admin','editor','viewer'])
    or exists (
      select 1 from public.screen_broadcast_targets target
      where target.broadcast_id = screen_broadcasts.id
        and public.user_can_access_screen(target.screen_id)
    )
  );
drop policy if exists "Team can read accessible broadcast targets" on public.screen_broadcast_targets;
create policy "Team can read accessible broadcast targets" on public.screen_broadcast_targets
  for select to authenticated using (
    public.team_has_role(array['admin','editor','viewer'])
    or public.user_can_access_screen(screen_id)
  );

create or replace function public.create_screen_broadcast(
  input_screen_ids uuid[],
  input_title text,
  input_body text,
  input_duration_minutes integer default 10
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_broadcast_id uuid;
  new_slide_id uuid;
  requested_count integer;
  active_count integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can send announcements' using errcode = '42501';
  end if;
  if input_screen_ids is null then raise exception 'Choose at least one screen'; end if;
  select count(distinct screen_id) into requested_count
  from unnest(input_screen_ids) as selected(screen_id);
  if requested_count < 1 or requested_count > 100 then
    raise exception 'Choose between 1 and 100 screens';
  end if;
  if input_duration_minutes is null or input_duration_minutes not between 1 and 1440 then
    raise exception 'Announcement duration must be between 1 and 1440 minutes';
  end if;
  if nullif(btrim(input_title), '') is null or char_length(btrim(input_title)) > 120 then
    raise exception 'Enter a title of up to 120 characters';
  end if;
  if nullif(btrim(input_body), '') is null or char_length(btrim(input_body)) > 1200 then
    raise exception 'Enter a message of up to 1200 characters';
  end if;

  select count(*) into active_count
  from public.screens screen_row
  where screen_row.id = any(input_screen_ids)
    and screen_row.is_active
    and screen_row.activated_at is not null
    and (public.team_has_role(array['admin','editor']) or public.user_can_access_screen(screen_row.id));
  if active_count <> requested_count then
    raise exception 'One or more selected screens are paused, unavailable, or outside your access';
  end if;

  insert into public.screen_broadcasts(title, body, ends_at, created_by)
  values (btrim(input_title), btrim(input_body), now() + make_interval(mins => input_duration_minutes), auth.uid())
  returning id into new_broadcast_id;
  insert into public.slides(broadcast_id, kind, title, body, duration_seconds, sort_order, is_active, expires_at)
  values (new_broadcast_id, 'text', btrim(input_title), btrim(input_body), 15, 0, true,
    now() + make_interval(mins => input_duration_minutes))
  returning id into new_slide_id;
  update public.screen_broadcasts set slide_id = new_slide_id where id = new_broadcast_id;
  update public.screen_broadcast_targets target
  set superseded_at = now()
  from public.screen_broadcasts older
  where target.broadcast_id = older.id
    and target.screen_id = any(input_screen_ids)
    and target.superseded_at is null
    and older.id <> new_broadcast_id
    and older.cancelled_at is null
    and older.starts_at <= now()
    and older.ends_at > now();
  insert into public.screen_broadcast_targets(broadcast_id, screen_id)
  select new_broadcast_id, target_id
  from (select distinct selected.screen_id as target_id from unnest(input_screen_ids) as selected(screen_id)) targets;
  insert into public.screen_commands(screen_id, command)
  select distinct selected.screen_id, 'sync_now'
  from unnest(input_screen_ids) as selected(screen_id)
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return new_broadcast_id;
end;
$$;
revoke all on function public.create_screen_broadcast(uuid[], text, text, integer) from public, anon;
grant execute on function public.create_screen_broadcast(uuid[], text, text, integer) to authenticated;

create or replace function public.cancel_screen_broadcast(input_broadcast_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target_count integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can cancel announcements' using errcode = '42501';
  end if;
  update public.screen_broadcasts
  set cancelled_at = now(), ends_at = now()
  where id = input_broadcast_id and cancelled_at is null and ends_at > now();
  if not found then raise exception 'The announcement is no longer active'; end if;

  select count(*) into target_count
  from public.screen_broadcast_targets
  where broadcast_id = input_broadcast_id and superseded_at is null;
  insert into public.screen_commands(screen_id, command)
  select screen_id, 'sync_now'
  from public.screen_broadcast_targets
  where broadcast_id = input_broadcast_id and superseded_at is null
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return target_count;
end;
$$;
revoke all on function public.cancel_screen_broadcast(uuid) from public, anon;
grant execute on function public.cancel_screen_broadcast(uuid) to authenticated;

-- The announcement rides alongside the last published playlist snapshot.
-- Its expiration is embedded so the player also returns to normal content offline.
create or replace function public.player_publication_snapshot(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with player_screen as (
    select id, layout_type, layout_text
    from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ), latest_publication as (
    select publication.revision, publication.payload
    from public.screen_publications publication
    join player_screen on player_screen.id = publication.screen_id
    order by publication.revision desc
    limit 1
  ), published_items as (
    select item, item_position, false as is_forced
    from latest_publication publication
    cross join lateral jsonb_array_elements(publication.payload) with ordinality as snapshot(item, item_position)
    where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now()
  ), existing_casts as (
    select live.item, live.ordinality + 1 as item_position, true as is_forced
    from player_screen
    cross join lateral public.player_playlist_source(player_screen.id) with ordinality as live(item, ordinality)
    where live.item->>'forced' = 'true'
      and (live.item->>'forced_until' is null or (live.item->>'forced_until')::timestamptz > now())
      and (live.item->>'expires_at' is null or (live.item->>'expires_at')::timestamptz > now())
  ), active_broadcast as (
    select jsonb_build_object(
      'id', broadcast.slide_id,
      'broadcast_id', broadcast.id,
      'kind', 'text',
      'title', broadcast.title,
      'body', broadcast.body,
      'duration_seconds', 15,
      'sort_order', 0,
      'created_at', broadcast.created_at,
      'is_active', true,
      'forced', true,
      'forced_until', broadcast.ends_at,
      'expires_at', broadcast.ends_at,
      'layout_type', player_screen.layout_type,
      'layout_text', player_screen.layout_text
    ) as item
    from player_screen
    join public.screen_broadcast_targets target on target.screen_id = player_screen.id
    join public.screen_broadcasts broadcast on broadcast.id = target.broadcast_id
    where broadcast.cancelled_at is null
      and target.superseded_at is null
      and broadcast.starts_at <= now()
      and broadcast.ends_at > now()
    order by broadcast.created_at desc, broadcast.id
    limit 1
  ), all_items as (
    select item, item_position, is_forced from published_items
    union all
    select item, item_position, is_forced from existing_casts
    union all
    select item, 0 as item_position, true as is_forced from active_broadcast
  )
  select jsonb_build_object(
    'revision', latest_publication.revision,
    'items', coalesce((
      select jsonb_agg(all_items.item order by all_items.is_forced desc, all_items.item_position)
      from all_items
    ), '[]'::jsonb)
  )
  from latest_publication
  where exists (select 1 from player_screen);
$$;
revoke all on function public.player_publication_snapshot(uuid) from public;
grant execute on function public.player_publication_snapshot(uuid) to anon, authenticated;

-- Heartbeat validation accepts a slide only when it is in the screen's
-- published snapshot or active temporary overlay, including broadcasts.
create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.screens screen_row
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where screen_row.id = input_screen_id
    and screen_row.is_active
    and (input_current_slide_id is null or exists (
      select 1
      from jsonb_array_elements(coalesce(
        public.player_publication_snapshot(input_screen_id)->'items', '[]'::jsonb
      )) published(item)
      where published.item->>'id' = input_current_slide_id::text
    ));
end;
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

commit;
-- Scheduled and media-backed broadcasts. Future items are sent to offline
-- capable players early, with their start/end window embedded in the cache.
begin;

alter table public.screen_broadcasts
  add column if not exists kind text not null default 'text',
  add column if not exists source_url text,
  add column if not exists duration_seconds integer not null default 60;
alter table public.screen_broadcasts drop constraint if exists screen_broadcasts_kind_check;
alter table public.screen_broadcasts add constraint screen_broadcasts_kind_check
  check (kind in ('text','image','video'));
alter table public.screen_broadcasts drop constraint if exists screen_broadcasts_duration_seconds_check;
alter table public.screen_broadcasts add constraint screen_broadcasts_duration_seconds_check
  check (duration_seconds between 5 and 600);

drop function if exists public.create_screen_broadcast(uuid[], text, text, integer);
create or replace function public.create_screen_broadcast(
  input_screen_ids uuid[],
  input_title text,
  input_body text,
  input_duration_minutes integer default 10,
  input_start_at timestamptz default now(),
  input_asset_id uuid default null,
  input_duration_seconds integer default 60
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_broadcast_id uuid;
  new_slide_id uuid;
  requested_count integer;
  active_count integer;
  broadcast_start timestamptz;
  broadcast_end timestamptz;
  broadcast_kind text := 'text';
  broadcast_source_url text;
  asset_expiration timestamptz;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can send announcements' using errcode = '42501';
  end if;
  if input_screen_ids is null then raise exception 'Choose at least one screen'; end if;
  select count(distinct screen_id) into requested_count
  from unnest(input_screen_ids) as selected(screen_id);
  if requested_count < 1 or requested_count > 100 then
    raise exception 'Choose between 1 and 100 screens';
  end if;
  if input_duration_minutes is null or input_duration_minutes not between 1 and 1440 then
    raise exception 'Announcement duration must be between 1 and 1440 minutes';
  end if;
  if input_start_at is null or input_start_at < now() - interval '2 minutes'
     or input_start_at > now() + interval '90 days' then
    raise exception 'Choose a start time between now and 90 days from now';
  end if;
  broadcast_start := greatest(input_start_at, now());
  broadcast_end := broadcast_start + make_interval(mins => input_duration_minutes);
  if input_duration_seconds is null or input_duration_seconds not between 5 and 600 then
    raise exception 'Content display duration must be between 5 and 600 seconds';
  end if;
  if nullif(btrim(input_title), '') is null or char_length(btrim(input_title)) > 120 then
    raise exception 'Enter a title of up to 120 characters';
  end if;
  if char_length(coalesce(input_body, '')) > 1200 then
    raise exception 'Message must be no longer than 1200 characters';
  end if;
  if input_asset_id is null and nullif(btrim(input_body), '') is null then
    raise exception 'Enter a message or choose an image/video from the media library';
  end if;

  if input_asset_id is not null then
    select asset.kind, asset.source_url, asset.expires_at
      into broadcast_kind, broadcast_source_url, asset_expiration
    from public.media_library asset
    where asset.id = input_asset_id;
    if not found or broadcast_kind not in ('image','video')
       or broadcast_source_url is null
       or broadcast_source_url !~* '^https?://' then
      raise exception 'Choose an available image or video from the media library';
    end if;
    if asset_expiration is not null and asset_expiration <= broadcast_end then
      raise exception 'The selected media expires before the broadcast ends';
    end if;
  end if;

  select count(*) into active_count
  from public.screens screen_row
  where screen_row.id = any(input_screen_ids)
    and screen_row.is_active
    and screen_row.activated_at is not null
    and (public.team_has_role(array['admin','editor']) or public.user_can_access_screen(screen_row.id));
  if active_count <> requested_count then
    raise exception 'One or more selected screens are paused, unavailable, or outside your access';
  end if;

  insert into public.screen_broadcasts(title, body, kind, source_url, duration_seconds, starts_at, ends_at, created_by)
  values (btrim(input_title), coalesce(input_body, ''), broadcast_kind, broadcast_source_url,
    input_duration_seconds, broadcast_start, broadcast_end, auth.uid())
  returning id into new_broadcast_id;
  insert into public.slides(broadcast_id, kind, title, body, source_url, duration_seconds, sort_order, is_active, expires_at)
  values (new_broadcast_id, broadcast_kind, btrim(input_title), coalesce(input_body, ''),
    broadcast_source_url, input_duration_seconds, 0, true, broadcast_end)
  returning id into new_slide_id;
  update public.screen_broadcasts set slide_id = new_slide_id where id = new_broadcast_id;

  -- A later overlapping programme takes over at its start. Before that time,
  -- the older programme remains eligible, including in an offline cache.
  update public.screen_broadcast_targets target
  set superseded_at = broadcast_start
  from public.screen_broadcasts older
  where target.broadcast_id = older.id
    and target.screen_id = any(input_screen_ids)
    and (target.superseded_at is null or target.superseded_at > broadcast_start)
    and older.id <> new_broadcast_id
    and older.cancelled_at is null
    and older.starts_at < broadcast_start
    and older.ends_at > broadcast_start;
  insert into public.screen_broadcast_targets(broadcast_id, screen_id)
  select new_broadcast_id, selected.screen_id
  from (select distinct unnest(input_screen_ids) as screen_id) selected;
  insert into public.screen_commands(screen_id, command)
  select distinct selected.screen_id, 'sync_now'
  from unnest(input_screen_ids) as selected(screen_id)
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return new_broadcast_id;
end;
$$;
revoke all on function public.create_screen_broadcast(uuid[], text, text, integer, timestamptz, uuid, integer) from public, anon;
grant execute on function public.create_screen_broadcast(uuid[], text, text, integer, timestamptz, uuid, integer) to authenticated;

create or replace function public.cancel_screen_broadcast(input_broadcast_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target_count integer;
  broadcast_start timestamptz;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can cancel announcements' using errcode = '42501';
  end if;
  select starts_at into broadcast_start
  from public.screen_broadcasts
  where id = input_broadcast_id and cancelled_at is null and ends_at > now()
  for update;
  if not found then raise exception 'The announcement is no longer active'; end if;
  update public.screen_broadcasts
  set cancelled_at = now(),
      ends_at = greatest(now(), starts_at + interval '1 second')
  where id = input_broadcast_id;

  if broadcast_start > now() then
    update public.screen_broadcast_targets older_target
    set superseded_at = (
      select min(candidate.starts_at)
      from public.screen_broadcast_targets candidate_target
      join public.screen_broadcasts candidate on candidate.id = candidate_target.broadcast_id
      join public.screen_broadcasts older on older.id = older_target.broadcast_id
      where candidate_target.screen_id = older_target.screen_id
        and candidate.id <> input_broadcast_id
        and candidate.cancelled_at is null
        and candidate.starts_at > older.starts_at
        and candidate.starts_at < older.ends_at
        and candidate.ends_at > now()
        and (candidate_target.superseded_at is null or candidate_target.superseded_at > now())
        and candidate.starts_at > now()
    )
    from public.screen_broadcasts older
    where older_target.broadcast_id = older.id
      and older_target.superseded_at = broadcast_start
      and older.id <> input_broadcast_id
      and older.cancelled_at is null;
  end if;

  -- If another announcement is already live on the same screen, the older
  -- item must stay superseded now. Otherwise let it resume at the next
  -- scheduled announcement, or remove the boundary if none remains.
  if broadcast_start > now() then
    update public.screen_broadcast_targets older_target
    set superseded_at = now()
    from public.screen_broadcasts older
    where older_target.broadcast_id = older.id
      and older_target.superseded_at = broadcast_start
      and older.id <> input_broadcast_id
      and older.cancelled_at is null
      and exists (
        select 1
        from public.screen_broadcast_targets active_target
        join public.screen_broadcasts active_broadcast on active_broadcast.id = active_target.broadcast_id
        where active_target.screen_id = older_target.screen_id
          and active_broadcast.id <> input_broadcast_id
          and active_broadcast.cancelled_at is null
          and active_broadcast.starts_at <= now()
          and active_broadcast.ends_at > now()
          and active_broadcast.starts_at > older.starts_at
          and active_broadcast.starts_at < older.ends_at
          and (active_target.superseded_at is null or active_target.superseded_at > now())
      );
  end if;

  select count(*) into target_count
  from public.screen_broadcast_targets
  where broadcast_id = input_broadcast_id
    and (superseded_at is null or superseded_at > now());
  insert into public.screen_commands(screen_id, command)
  select screen_id, 'sync_now'
  from public.screen_broadcast_targets
  where broadcast_id = input_broadcast_id
    and (superseded_at is null or superseded_at > now())
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return target_count;
end;
$$;
revoke all on function public.cancel_screen_broadcast(uuid) from public, anon;
grant execute on function public.cancel_screen_broadcast(uuid) to authenticated;

create or replace function public.player_publication_snapshot(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with player_screen as (
    select id, layout_type, layout_text, player_version
    from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ), latest_publication as (
    select publication.revision, publication.payload
    from public.screen_publications publication
    join player_screen on player_screen.id = publication.screen_id
    order by publication.revision desc
    limit 1
  ), published_items as (
    select item, item_position, false as is_forced
    from latest_publication publication
    cross join lateral jsonb_array_elements(publication.payload) with ordinality as snapshot(item, item_position)
    where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now()
  ), existing_casts as (
    select live.item, live.ordinality + 1 as item_position, true as is_forced
    from player_screen
    cross join lateral public.player_playlist_source(player_screen.id) with ordinality as live(item, ordinality)
    where live.item->>'forced' = 'true'
      and (live.item->>'forced_until' is null or (live.item->>'forced_until')::timestamptz > now())
      and (live.item->>'expires_at' is null or (live.item->>'expires_at')::timestamptz > now())
  ), broadcast_items as (
    select jsonb_build_object(
      'id', broadcast.slide_id,
      'broadcast_id', broadcast.id,
      'kind', broadcast.kind,
      'title', broadcast.title,
      'body', broadcast.body,
      'source_url', broadcast.source_url,
      'duration_seconds', broadcast.duration_seconds,
      'sort_order', 0,
      'created_at', broadcast.created_at,
      'is_active', true,
      'forced', true,
      'forced_from', broadcast.starts_at,
      'forced_until', case when target.superseded_at is not null and target.superseded_at < broadcast.ends_at then target.superseded_at else broadcast.ends_at end,
      'expires_at', case when target.superseded_at is not null and target.superseded_at < broadcast.ends_at then target.superseded_at else broadcast.ends_at end,
      'layout_type', player_screen.layout_type,
      'layout_text', player_screen.layout_text
    ) as item,
    row_number() over (order by broadcast.starts_at, broadcast.created_at, broadcast.id)::bigint as item_position
    from player_screen
    join public.screen_broadcast_targets target on target.screen_id = player_screen.id
    join public.screen_broadcasts broadcast on broadcast.id = target.broadcast_id
    where broadcast.cancelled_at is null
      and (target.superseded_at is null or target.superseded_at > now())
      and broadcast.ends_at > now()
      and (broadcast.starts_at <= now() or player_screen.player_version ~ '^([2-9]|[1-9][0-9]+)[.]'
        or player_screen.player_version ~ '^1[.](1[9]|[2-9][0-9])[.]')
    order by broadcast.starts_at, broadcast.created_at, broadcast.id
    limit 50
  ), all_items as (
    select item, item_position, is_forced from published_items
    union all
    select item, item_position, is_forced from existing_casts
    union all
    select item, item_position, true as is_forced from broadcast_items
  )
  select jsonb_build_object(
    'revision', latest_publication.revision,
    'items', coalesce((
      select jsonb_agg(all_items.item order by all_items.is_forced desc, all_items.item_position)
      from all_items
    ), '[]'::jsonb)
  )
  from latest_publication
  where exists (select 1 from player_screen);
$$;
revoke all on function public.player_publication_snapshot(uuid) from public;
grant execute on function public.player_publication_snapshot(uuid) to anon, authenticated;

create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.screens screen_row
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where screen_row.id = input_screen_id
    and screen_row.is_active
    and (input_current_slide_id is null or exists (
      select 1 from jsonb_array_elements(coalesce(
        public.player_publication_snapshot(input_screen_id)->'items', '[]'::jsonb
      )) published(item)
      where published.item->>'id' = input_current_slide_id::text
    ));
end;
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

commit;
-- Bound reported playback to the last known heartbeat and start a fresh
-- playback segment when a player reconnects after a real offline gap.
begin;

create or replace function public.capture_playback_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  prior_end timestamptz;
begin
  if old.current_slide_id is not distinct from new.current_slide_id then
    return new;
  end if;

  prior_end := case
    when old.last_seen_at is not null and old.last_seen_at < now() - interval '45 seconds'
      then old.last_seen_at
    else now()
  end;

  update public.playback_events
  set ended_at = greatest(started_at, prior_end)
  where screen_id = new.id and ended_at is null;

  if new.current_slide_id is not null
     and new.is_active
     and new.activated_at is not null then
    insert into public.playback_events(
      screen_id, screen_name, screen_group_id, slide_id, content_title, content_kind
    ) values (
      new.id, new.name, new.group_id, new.current_slide_id,
      coalesce(nullif(new.current_title, ''), 'Innehåll'), new.current_kind
    );
  end if;

  return new;
end;
$$;
revoke all on function public.capture_playback_transition() from public, anon, authenticated;

create or replace function public.record_playback_after_offline_gap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.last_seen_at is null
     or old.last_seen_at >= now() - interval '45 seconds'
     or new.current_slide_id is distinct from old.current_slide_id
     or new.current_slide_id is null
     or not new.is_active
     or new.activated_at is null then
    return new;
  end if;

  -- The screen health cron may already have closed the row. This also handles
  -- reconnects that happen before the next cron tick.
  update public.playback_events
  set ended_at = greatest(started_at, least(old.last_seen_at, now()))
  where screen_id = new.id and ended_at is null;

  insert into public.playback_events(
    screen_id, screen_name, screen_group_id, slide_id, content_title, content_kind
  ) values (
    new.id, new.name, new.group_id, new.current_slide_id,
    coalesce(nullif(new.current_title, ''), 'Innehåll'), new.current_kind
  );

  return new;
end;
$$;
revoke all on function public.record_playback_after_offline_gap() from public, anon, authenticated;
drop trigger if exists record_playback_after_offline_gap on public.screens;
create trigger record_playback_after_offline_gap
  after update of last_seen_at on public.screens
  for each row execute function public.record_playback_after_offline_gap();

create or replace function public.record_screen_health_transitions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  screen_row record;
  previous_status text;
  next_status text;
  inserted_count integer := 0;
begin
  for screen_row in
    select id, name, group_id, last_seen_at, activated_at
    from public.screens
    where is_active and activated_at is not null
  loop
    perform pg_advisory_xact_lock(hashtextextended(screen_row.id::text, 0));
    select event.status into previous_status
    from public.screen_health_events event
    where event.screen_id = screen_row.id
    order by event.observed_at desc, event.id desc
    limit 1;

    next_status := case
      when screen_row.last_seen_at >= now() - interval '45 seconds' then 'online'
      else 'offline'
    end;

    if next_status = 'offline' and screen_row.last_seen_at is not null then
      update public.playback_events
      set ended_at = greatest(started_at, least(screen_row.last_seen_at, now()))
      where screen_id = screen_row.id and ended_at is null;
    end if;

    if previous_status is distinct from next_status then
      insert into public.screen_health_events(
        screen_id, screen_name, screen_group_id, status, observed_at, last_seen_at
      ) values (
        screen_row.id, screen_row.name, screen_row.group_id,
        next_status, now(), screen_row.last_seen_at
      );
      inserted_count := inserted_count + 1;
    end if;
  end loop;
  return inserted_count;
end;
$$;
revoke all on function public.record_screen_health_transitions() from public, anon, authenticated;

commit;
-- Aggregate reported playback across the full selected period under the same
-- row-level access rules as the detailed playback history.
begin;

create or replace function public.team_playback_summary(
  input_from timestamptz,
  input_to timestamptz,
  input_screen_id uuid default null
)
returns table (
  slide_id uuid,
  content_title text,
  content_kind text,
  screen_count bigint,
  playback_count bigint,
  reported_seconds numeric
)
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;
  if input_from is null or input_to is null or input_to <= input_from then
    raise exception 'Choose a valid playback reporting period';
  end if;
  if input_to - input_from > interval '366 days' then
    raise exception 'Playback reporting period cannot exceed 366 days';
  end if;

  return query
  select event.slide_id,
         event.content_title,
         event.content_kind,
         count(distinct event.screen_id),
         count(*)::bigint,
         coalesce(sum(greatest(0, extract(epoch from (
           least(event.ended_at, input_to) - greatest(event.started_at, input_from)
         )))), 0)::numeric
  from public.playback_events event
  where event.ended_at is not null
    and event.started_at < input_to
    and event.ended_at > input_from
    and (input_screen_id is null or event.screen_id = input_screen_id)
  group by event.slide_id, event.content_title, event.content_kind
  order by sum(greatest(0, extract(epoch from (
    least(event.ended_at, input_to) - greatest(event.started_at, input_from)
  )))) desc, event.content_title, event.slide_id
  limit 100;
end;
$$;
revoke all on function public.team_playback_summary(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.team_playback_summary(timestamptz, timestamptz, uuid) to authenticated;

commit;
-- Summarize which target screens actually reported displaying each broadcast.
-- SECURITY INVOKER keeps the underlying screen and playback RLS policies active.
begin;

create or replace function public.team_broadcast_delivery_summary(input_broadcast_ids uuid[])
returns table (
  broadcast_id uuid,
  screen_id uuid,
  first_shown_at timestamptz,
  last_shown_at timestamptz,
  playback_count bigint
)
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;
  if input_broadcast_ids is null or cardinality(input_broadcast_ids) > 100 then
    raise exception 'Choose no more than 100 broadcasts';
  end if;

  return query
  select broadcast.id,
         target.screen_id,
         min(event_row.started_at) filter (where event_row.id is not null),
         max(event_row.started_at) filter (where event_row.id is not null),
         count(event_row.id)::bigint
  from public.screen_broadcasts broadcast
  join public.screen_broadcast_targets target on target.broadcast_id = broadcast.id
  left join public.playback_events event_row
    on event_row.screen_id = target.screen_id
    and event_row.slide_id = broadcast.slide_id
    and event_row.started_at >= broadcast.starts_at
    and event_row.started_at < broadcast.ends_at
  where broadcast.id = any(input_broadcast_ids)
  group by broadcast.id, target.screen_id
  order by broadcast.id, target.screen_id;
end;
$$;
revoke all on function public.team_broadcast_delivery_summary(uuid[]) from public, anon;
grant execute on function public.team_broadcast_delivery_summary(uuid[]) to authenticated;

commit;

-- Persist team-wide thresholds for in-app screen and feed operations alerts.
begin;

create table if not exists public.team_operational_settings (
  id boolean primary key default true check (id),
  offline_alert_after_minutes integer not null default 3
    check (offline_alert_after_minutes between 1 and 60),
  command_alert_after_minutes integer not null default 2
    check (command_alert_after_minutes between 1 and 30),
  feed_error_window_minutes integer not null default 15
    check (feed_error_window_minutes between 5 and 240),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into public.team_operational_settings(id) values (true)
on conflict (id) do nothing;

alter table public.team_operational_settings enable row level security;
revoke all on public.team_operational_settings from public, anon, authenticated;
grant select, update on public.team_operational_settings to authenticated;
drop policy if exists "Team can read operational alert settings" on public.team_operational_settings;
create policy "Team can read operational alert settings"
  on public.team_operational_settings for select to authenticated
  using (public.current_team_role() is not null);
drop policy if exists "Admins update operational alert settings" on public.team_operational_settings;
create policy "Admins update operational alert settings"
  on public.team_operational_settings for update to authenticated
  using (public.team_has_role(array['admin']))
  with check (public.team_has_role(array['admin']));

commit;

-- Migration: 20261130_reorder_channel_playlists.sql
-- Reorder every playlist within one channel as a single, validated operation.
begin;

create or replace function public.reorder_channel_playlists(
  input_channel_id uuid,
  input_playlist_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_count integer;
  requested_count integer;
  distinct_count integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin', 'editor') then
    raise exception 'Only admins and editors can reorder channel playlists' using errcode = '42501';
  end if;
  if input_playlist_ids is null or cardinality(input_playlist_ids) = 0 or cardinality(input_playlist_ids) > 200 then
    raise exception 'Choose between 1 and 200 channel playlists';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(input_channel_id::text, 930));
  perform 1 from public.channels where id = input_channel_id for update;
  if not found then raise exception 'Channel was not found'; end if;

  requested_count := cardinality(input_playlist_ids);
  select count(distinct requested.playlist_id)::integer
    into distinct_count
    from unnest(input_playlist_ids) as requested(playlist_id);
  if distinct_count <> requested_count then
    raise exception 'Channel playlist order contains duplicates';
  end if;

  select count(*)::integer into current_count
    from public.channel_playlists
    where channel_id = input_channel_id;
  if current_count <> requested_count
    or exists (
      select 1 from public.channel_playlists membership
      where membership.channel_id = input_channel_id
        and not (membership.playlist_id = any(input_playlist_ids))
    )
    or exists (
      select 1 from unnest(input_playlist_ids) as requested(playlist_id)
      where not exists (
        select 1 from public.channel_playlists membership
        where membership.channel_id = input_channel_id
          and membership.playlist_id = requested.playlist_id
      )
    ) then
    raise exception 'Channel playlist order is stale; reload and try again';
  end if;

  update public.channel_playlists membership
  set sort_order = requested.ordinality::integer - 1
  from unnest(input_playlist_ids) with ordinality as requested(playlist_id, ordinality)
  where membership.channel_id = input_channel_id
    and membership.playlist_id = requested.playlist_id;
end;
$$;

revoke all on function public.reorder_channel_playlists(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_channel_playlists(uuid, uuid[]) to authenticated;

commit;
