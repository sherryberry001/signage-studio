-- Keep immutable playlist snapshots and let editors start a new playlist from
-- an earlier version without changing any screen's current draft or publish.
begin;

create table if not exists public.playlist_versions (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  version integer not null check (version > 0),
  playlist_name text not null check (char_length(playlist_name) between 1 and 80),
  items jsonb not null check (jsonb_typeof(items) = 'array'),
  snapshot_hash text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (playlist_id, version),
  unique (playlist_id, snapshot_hash)
);
create index if not exists playlist_versions_history_idx
  on public.playlist_versions(playlist_id, version desc);

alter table public.playlist_versions enable row level security;
revoke all on public.playlist_versions from public, anon, authenticated;
grant select (id, playlist_id, version, playlist_name, created_by, created_at)
  on public.playlist_versions to authenticated;
drop policy if exists "Team members read playlist versions" on public.playlist_versions;
create policy "Team members read playlist versions" on public.playlist_versions
  for select to authenticated
  using (
    public.team_has_role(array['admin','editor','viewer'])
    or public.user_can_access_playlist(playlist_id)
  );

create or replace function public.record_playlist_version(input_playlist_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  playlist_name_value text;
  items_value jsonb;
  snapshot_hash_value text;
  next_version integer;
begin
  select playlist.name into playlist_name_value
  from public.playlists playlist
  where playlist.id = input_playlist_id
  for update;
  if not found then return; end if;

  select coalesce(jsonb_agg(to_jsonb(slide)
    order by slide.sort_order, slide.created_at, slide.id), '[]'::jsonb)
    into items_value
  from public.slides slide
  where slide.playlist_id = input_playlist_id;

  snapshot_hash_value := encode(digest(
    jsonb_build_object('name', playlist_name_value, 'items', items_value)::text,
    'sha256'
  ), 'hex');

  if exists (
    select 1 from public.playlist_versions version_row
    where version_row.playlist_id = input_playlist_id
      and version_row.snapshot_hash = snapshot_hash_value
  ) then return; end if;

  select coalesce(max(version_row.version), 0) + 1 into next_version
  from public.playlist_versions version_row
  where version_row.playlist_id = input_playlist_id;

  insert into public.playlist_versions(
    playlist_id, version, playlist_name, items, snapshot_hash, created_by
  ) values (
    input_playlist_id, next_version, playlist_name_value, items_value,
    snapshot_hash_value, auth.uid()
  ) on conflict (playlist_id, snapshot_hash) do nothing;
end;
$$;
revoke all on function public.record_playlist_version(uuid) from public, anon, authenticated;

create or replace function public.capture_playlist_version_from_slides()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  affected_playlist_id uuid;
begin
  if tg_op = 'INSERT' then
    for affected_playlist_id in
      select distinct new_row.playlist_id from new_rows new_row
      where new_row.playlist_id is not null
    loop
      perform public.record_playlist_version(affected_playlist_id);
    end loop;
  elsif tg_op = 'UPDATE' then
    for affected_playlist_id in
      select playlist_ids.playlist_id
      from (
        select new_row.playlist_id from new_rows new_row
        union
        select old_row.playlist_id from old_rows old_row
      ) playlist_ids
      where playlist_ids.playlist_id is not null
    loop
      perform public.record_playlist_version(affected_playlist_id);
    end loop;
  elsif tg_op = 'DELETE' then
    for affected_playlist_id in
      select distinct old_row.playlist_id from old_rows old_row
      where old_row.playlist_id is not null
    loop
      perform public.record_playlist_version(affected_playlist_id);
    end loop;
  end if;
  return null;
end;
$$;
revoke all on function public.capture_playlist_version_from_slides() from public, anon, authenticated;

drop trigger if exists capture_playlist_version_after_slide_insert on public.slides;
create trigger capture_playlist_version_after_slide_insert
  after insert on public.slides
  referencing new table as new_rows
  for each statement execute function public.capture_playlist_version_from_slides();
drop trigger if exists capture_playlist_version_after_slide_update on public.slides;
create trigger capture_playlist_version_after_slide_update
  after update on public.slides
  referencing old table as old_rows new table as new_rows
  for each statement execute function public.capture_playlist_version_from_slides();
drop trigger if exists capture_playlist_version_after_slide_delete on public.slides;
create trigger capture_playlist_version_after_slide_delete
  after delete on public.slides
  referencing old table as old_rows
  for each statement execute function public.capture_playlist_version_from_slides();

create or replace function public.capture_playlist_version_after_playlist_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.record_playlist_version(new.id);
  return new;
end;
$$;
revoke all on function public.capture_playlist_version_after_playlist_change() from public, anon, authenticated;
drop trigger if exists capture_playlist_version_after_playlist_insert on public.playlists;
create trigger capture_playlist_version_after_playlist_insert
  after insert on public.playlists
  for each row execute function public.capture_playlist_version_after_playlist_change();
drop trigger if exists capture_playlist_version_after_playlist_rename on public.playlists;
create trigger capture_playlist_version_after_playlist_rename
  after update of name on public.playlists
  for each row when (old.name is distinct from new.name)
  execute function public.capture_playlist_version_after_playlist_change();

create or replace function public.create_playlist_from_version(
  input_version_id uuid,
  input_name text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  version_row public.playlist_versions%rowtype;
  target_name text := btrim(coalesce(input_name, ''));
  new_playlist_id uuid;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can create a playlist from history' using errcode = '42501';
  end if;
  if char_length(target_name) not between 1 and 80 then
    raise exception 'Playlist name must be between 1 and 80 characters';
  end if;

  select * into version_row
  from public.playlist_versions
  where id = input_version_id;
  if not found then raise exception 'Playlist version was not found'; end if;

  insert into public.playlists(name) values (target_name)
  returning id into new_playlist_id;

  insert into public.slides(
    screen_id, playlist_id, kind, title, body, source_url, library_asset_id,
    integration_id, expires_at, duration_seconds, refresh_interval_seconds,
    sort_order, is_active, active_from, active_until, weekdays,
    daily_start_time, daily_end_time
  )
  select
    null, new_playlist_id, item.kind, item.title, item.body, item.source_url,
    case when item.library_asset_id is not null and exists (
      select 1 from public.media_library asset where asset.id = item.library_asset_id
    ) then item.library_asset_id else null end,
    case when item.integration_id is not null and exists (
      select 1 from public.signage_integrations integration where integration.id = item.integration_id
    ) then item.integration_id else null end,
    item.expires_at, item.duration_seconds, item.refresh_interval_seconds,
    item.sort_order, item.is_active, item.active_from, item.active_until,
    item.weekdays, item.daily_start_time, item.daily_end_time
  from jsonb_populate_recordset(null::public.slides, version_row.items) as item;

  return new_playlist_id;
end;
$$;
revoke all on function public.create_playlist_from_version(uuid, text) from public, anon;
grant execute on function public.create_playlist_from_version(uuid, text) to authenticated;

-- Capture the initial snapshot for playlists that predate this migration.
do $$
declare playlist_row record;
begin
  for playlist_row in select id from public.playlists loop
    perform public.record_playlist_version(playlist_row.id);
  end loop;
end;
$$;

commit;
