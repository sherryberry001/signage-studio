-- Add read-only users whose access is limited to explicitly assigned screen groups.
begin;

alter table public.team_members drop constraint if exists team_members_role_check;
alter table public.team_members add constraint team_members_role_check
  check (role in ('admin', 'editor', 'viewer', 'group_member'));

create table if not exists public.screen_group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.screen_groups(id) on delete cascade,
  user_id uuid not null references public.team_members(user_id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (group_id, user_id)
);
create index if not exists screen_group_members_user_idx on public.screen_group_members(user_id, group_id);
alter table public.screen_group_members enable row level security;
grant select, insert, update, delete on public.screen_group_members to authenticated;
drop policy if exists "Admins manage screen group members" on public.screen_group_members;
create policy "Admins manage screen group members" on public.screen_group_members
  for all to authenticated
  using (public.team_has_role(array['admin']))
  with check (public.team_has_role(array['admin']));
drop policy if exists "Members read own group access" on public.screen_group_members;
create policy "Members read own group access" on public.screen_group_members
  for select to authenticated using (user_id = auth.uid());

create or replace function public.user_can_access_group(input_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.screen_group_members sgm
    join public.team_members tm on tm.user_id = sgm.user_id
    where sgm.group_id = input_group_id
      and sgm.user_id = auth.uid()
      and tm.role = 'group_member'
  );
$$;

create or replace function public.user_can_access_screen(input_screen_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.screens sc
    where sc.id = input_screen_id
      and public.user_can_access_group(sc.group_id)
  );
$$;

create or replace function public.user_can_access_channel(input_channel_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.screen_channel_schedules scs
    join public.screens sc on sc.id = scs.screen_id
    where scs.channel_id = input_channel_id
      and public.user_can_access_group(sc.group_id)
  );
$$;

create or replace function public.user_can_access_playlist(input_playlist_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.screens sc
    where sc.playlist_id = input_playlist_id
      and public.user_can_access_group(sc.group_id)
  ) or exists (
    select 1
    from public.slides sl
    join public.screens sc on sc.id = sl.screen_id
    where sl.playlist_id = input_playlist_id
      and public.user_can_access_group(sc.group_id)
  ) or exists (
    select 1
    from public.channel_playlists cp
    join public.screen_channel_schedules scs on scs.channel_id = cp.channel_id
    join public.screens sc on sc.id = scs.screen_id
    where cp.playlist_id = input_playlist_id
      and public.user_can_access_group(sc.group_id)
  );
$$;

create or replace function public.user_can_access_slide(input_slide_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.slides sl
    where sl.id = input_slide_id
      and (
        (sl.screen_id is not null and public.user_can_access_screen(sl.screen_id))
        or (sl.playlist_id is not null and public.user_can_access_playlist(sl.playlist_id))
      )
  );
$$;

create or replace function public.user_can_access_media_asset(input_asset_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.slides sl
    where sl.library_asset_id = input_asset_id
      and public.user_can_access_slide(sl.id)
  );
$$;

revoke all on function public.user_can_access_group(uuid) from public;
revoke all on function public.user_can_access_screen(uuid) from public;
revoke all on function public.user_can_access_channel(uuid) from public;
revoke all on function public.user_can_access_playlist(uuid) from public;
revoke all on function public.user_can_access_slide(uuid) from public;
revoke all on function public.user_can_access_media_asset(uuid) from public;
grant execute on function public.user_can_access_group(uuid) to authenticated;
grant execute on function public.user_can_access_screen(uuid) to authenticated;
grant execute on function public.user_can_access_channel(uuid) to authenticated;
grant execute on function public.user_can_access_playlist(uuid) to authenticated;
grant execute on function public.user_can_access_slide(uuid) to authenticated;
grant execute on function public.user_can_access_media_asset(uuid) to authenticated;

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

drop policy if exists "Team members read screen groups" on public.screen_groups;
create policy "Team members read screen groups" on public.screen_groups
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_group(id));

drop policy if exists "Team members read screens" on public.screens;
create policy "Team members read screens" on public.screens
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_screen(id));

drop policy if exists "Team members read signage content" on public.slides;
create policy "Team members read signage content" on public.slides
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_slide(id));

drop policy if exists "Team members read playlists" on public.playlists;
create policy "Team members read playlists" on public.playlists
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_playlist(id));

drop policy if exists "Team can read media library" on public.media_library;
create policy "Team can read media library" on public.media_library
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_media_asset(id));

drop policy if exists "Team members read channels" on public.channels;
create policy "Team members read channels" on public.channels
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_channel(id));

drop policy if exists "Team members read channel playlists" on public.channel_playlists;
create policy "Team members read channel playlists" on public.channel_playlists
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_channel(channel_id));

drop policy if exists "Team members read channel schedules" on public.screen_channel_schedules;
create policy "Team members read channel schedules" on public.screen_channel_schedules
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_screen(screen_id));

drop policy if exists "Team can read screen command history" on public.screen_commands;
create policy "Team can read screen command history" on public.screen_commands
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']) or public.user_can_access_screen(screen_id));

commit;
