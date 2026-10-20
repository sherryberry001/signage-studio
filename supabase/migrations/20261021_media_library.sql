-- Shared, searchable content library. Playlist entries remain independent copies,
-- so editing one playlist never changes another display unexpectedly.
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
