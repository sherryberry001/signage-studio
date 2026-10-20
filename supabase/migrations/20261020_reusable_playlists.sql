-- Adds reusable playlists while preserving every existing screen and slide.
begin;

create table if not exists public.playlists (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.screens add column if not exists playlist_id uuid;
alter table public.slides add column if not exists playlist_id uuid;
alter table public.slides alter column screen_id drop not null;

alter table public.screens drop constraint if exists screens_playlist_id_fkey;
alter table public.screens add constraint screens_playlist_id_fkey
  foreign key (playlist_id) references public.playlists(id) on delete set null;
alter table public.slides drop constraint if exists slides_playlist_id_fkey;
alter table public.slides add constraint slides_playlist_id_fkey
  foreign key (playlist_id) references public.playlists(id) on delete cascade;

-- Give each existing screen a playlist and move its content into that playlist.
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

alter table public.slides drop constraint if exists slides_content_owner_check;
alter table public.slides add constraint slides_content_owner_check
  check ((screen_id is null) <> (playlist_id is null));

create index if not exists screens_playlist_idx on public.screens(playlist_id);
create index if not exists slides_playlist_order_idx on public.slides(playlist_id, sort_order, created_at);

grant select, insert, update, delete on public.playlists to authenticated;
alter table public.playlists enable row level security;
drop policy if exists "Admins manage playlists" on public.playlists;
create policy "Admins manage playlists" on public.playlists
  for all to authenticated using (true) with check (true);

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

commit;
