-- Shared searchable content library. Playlist entries retain a reference to
-- the asset so content changes propagate consistently across assigned screens.
begin;

create table if not exists public.media_library (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('text', 'video', 'feed', 'web', 'clock')),
  title text not null check (char_length(title) between 1 and 120),
  body text not null default '',
  source_url text,
  duration_seconds integer not null default 30 check (duration_seconds between 5 and 600),
  tags text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists media_library_title_idx on public.media_library using gin (to_tsvector('simple', title));
create index if not exists media_library_tags_idx on public.media_library using gin (tags);

alter table public.slides add column if not exists library_asset_id uuid references public.media_library(id) on delete set null;
create index if not exists slides_library_asset_idx on public.slides(library_asset_id) where library_asset_id is not null;

create or replace function public.sync_media_library_references()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.slides
  set kind = new.kind,
      title = new.title,
      body = new.body,
      source_url = new.source_url
  where library_asset_id = new.id;
  return new;
end;
$$;
revoke all on function public.sync_media_library_references() from public;
drop trigger if exists sync_media_library_references on public.media_library;
create trigger sync_media_library_references
  after update of kind, title, body, source_url on public.media_library
  for each row execute function public.sync_media_library_references();

alter table public.media_library enable row level security;
revoke all on public.media_library from anon;
grant select, insert, update, delete on public.media_library to authenticated;

drop policy if exists "Team can read media library" on public.media_library;
create policy "Team can read media library" on public.media_library
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']));
drop policy if exists "Editors manage media library" on public.media_library;
create policy "Editors manage media library" on public.media_library
  for all to authenticated
  using (public.team_has_role(array['admin','editor']))
  with check (public.team_has_role(array['admin','editor']));

commit;
