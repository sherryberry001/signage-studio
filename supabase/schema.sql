-- Signage Studio schema. Public content is readable by the TV player;
-- only authenticated administrators may change screens, slides, or media.

create extension if not exists pgcrypto;

create table if not exists public.playlists (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.screens (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 48),
  pair_code text unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  last_seen_at timestamptz,
  current_slide_id uuid,
  current_title text not null default 'Väntar på innehåll',
  current_body text not null default '',
  current_kind text,
  current_source_url text,
  forced_slide_id uuid,
  playlist_id uuid references public.playlists(id) on delete set null
);

create table if not exists public.slides (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid references public.screens(id) on delete set null,
  playlist_id uuid references public.playlists(id) on delete cascade,
  kind text not null check (kind in ('text', 'video', 'clock', 'feed', 'web')),
  title text not null default '',
  body text not null default '',
  source_url text,
  duration_seconds integer not null default 15 check (duration_seconds between 5 and 600),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  active_from timestamptz,
  active_until timestamptz,
  created_at timestamptz not null default now(),
  constraint slides_content_owner_check check ((screen_id is null) <> (playlist_id is null))
);

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
alter table public.slides alter column screen_id drop not null;

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
alter table public.slides add constraint slides_kind_check check (kind in ('text', 'video', 'clock', 'feed', 'web'));
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

alter table public.screens enable row level security;
alter table public.slides enable row level security;
alter table public.playlists enable row level security;

drop policy if exists "Public can read active screens" on public.screens;

drop policy if exists "Admins manage screens" on public.screens;
create policy "Admins manage screens" on public.screens
  for all to authenticated using (true) with check (true);

drop policy if exists "Public can read active signage content" on public.slides;

drop policy if exists "Admins manage signage content" on public.slides;
create policy "Admins manage signage content" on public.slides
  for all to authenticated using (true) with check (true);

drop policy if exists "Admins manage playlists" on public.playlists;
create policy "Admins manage playlists" on public.playlists
  for all to authenticated using (true) with check (true);

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
  array['video/mp4','video/webm','video/quicktime','application/vnd.apple.mpegurl','application/x-mpegURL'])
on conflict (id) do update set public = true, file_size_limit = 419430400,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Public can read signage videos" on storage.objects;
create policy "Public can read signage videos" on storage.objects
  for select to anon, authenticated using (bucket_id = 'signage-assets');

drop policy if exists "Admins upload signage videos" on storage.objects;
create policy "Admins upload signage videos" on storage.objects
  for insert to authenticated with check (bucket_id = 'signage-assets');

drop policy if exists "Admins update signage videos" on storage.objects;
create policy "Admins update signage videos" on storage.objects
  for update to authenticated using (bucket_id = 'signage-assets') with check (bucket_id = 'signage-assets');

drop policy if exists "Admins delete signage videos" on storage.objects;
create policy "Admins delete signage videos" on storage.objects
  for delete to authenticated using (bucket_id = 'signage-assets');
