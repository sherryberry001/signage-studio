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
