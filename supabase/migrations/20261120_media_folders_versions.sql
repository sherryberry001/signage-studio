-- Add flat media-library folders and immutable file-version history. Replaced
-- Storage objects are retained so published player snapshots keep working.
begin;

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

commit;
