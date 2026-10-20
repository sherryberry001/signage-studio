-- Replace "any authenticated user is admin" with explicit team roles.
begin;

create table if not exists public.team_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null check (role in ('admin', 'editor', 'viewer')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Preserve current access for accounts that already exist when this migration runs.
insert into public.team_members(user_id, email, role)
select id, email, 'admin' from auth.users where email is not null
on conflict (user_id) do nothing;

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
  if input_role not in ('admin', 'editor', 'viewer') then
    raise exception 'Role must be admin, editor, or viewer';
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
grant select on public.team_members to authenticated;
drop policy if exists "Members can read team roster" on public.team_members;
create policy "Members can read team roster" on public.team_members
  for select to authenticated
  using (user_id = auth.uid() or public.team_has_role(array['admin']));

-- Screens are visible to all team roles; only admins may manage devices.
drop policy if exists "Admins manage screens" on public.screens;
drop policy if exists "Team members read screens" on public.screens;
drop policy if exists "Admins insert screens" on public.screens;
drop policy if exists "Admins update screens" on public.screens;
drop policy if exists "Admins delete screens" on public.screens;
create policy "Team members read screens" on public.screens
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']));
create policy "Admins insert screens" on public.screens
  for insert to authenticated with check (public.team_has_role(array['admin']));
create policy "Admins update screens" on public.screens
  for update to authenticated using (public.team_has_role(array['admin'])) with check (public.team_has_role(array['admin']));
create policy "Admins delete screens" on public.screens
  for delete to authenticated using (public.team_has_role(array['admin']));

-- Editors can publish content and playlists; viewers are read-only.
drop policy if exists "Admins manage signage content" on public.slides;
drop policy if exists "Team members read signage content" on public.slides;
drop policy if exists "Editors insert signage content" on public.slides;
drop policy if exists "Editors update signage content" on public.slides;
drop policy if exists "Editors delete signage content" on public.slides;
create policy "Team members read signage content" on public.slides
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']));
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
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']));
create policy "Editors insert playlists" on public.playlists
  for insert to authenticated with check (public.team_has_role(array['admin','editor']));
create policy "Editors update playlists" on public.playlists
  for update to authenticated using (public.team_has_role(array['admin','editor'])) with check (public.team_has_role(array['admin','editor']));
create policy "Editors delete playlists" on public.playlists
  for delete to authenticated using (public.team_has_role(array['admin','editor']));

-- Storage uploads/deletes follow the same editor permissions.
drop policy if exists "Admins upload signage videos" on storage.objects;
create policy "Admins upload signage videos" on storage.objects
  for insert to authenticated with check (bucket_id = 'signage-assets' and public.team_has_role(array['admin','editor']));
drop policy if exists "Admins update signage videos" on storage.objects;
create policy "Admins update signage videos" on storage.objects
  for update to authenticated using (bucket_id = 'signage-assets' and public.team_has_role(array['admin','editor']))
  with check (bucket_id = 'signage-assets' and public.team_has_role(array['admin','editor']));
drop policy if exists "Admins delete signage videos" on storage.objects;
create policy "Admins delete signage videos" on storage.objects
  for delete to authenticated using (bucket_id = 'signage-assets' and public.team_has_role(array['admin','editor']));

commit;
