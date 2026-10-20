-- Signage Studio schema. Public content is readable by the TV player;
-- only authenticated administrators may change screens, slides, or media.

create extension if not exists pgcrypto;

create table if not exists public.screens (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 48),
  pair_code text unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  activated_at timestamptz
);

create table if not exists public.slides (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  kind text not null check (kind in ('text', 'video', 'clock', 'feed')),
  title text not null default '',
  body text not null default '',
  source_url text,
  duration_seconds integer not null default 15 check (duration_seconds between 5 and 600),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  active_from timestamptz,
  active_until timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists slides_screen_order_idx on public.slides(screen_id, sort_order);
create index if not exists slides_schedule_idx on public.slides(active_from, active_until);

grant select, insert, update, delete on public.screens, public.slides to authenticated;

alter table public.screens enable row level security;
alter table public.slides enable row level security;

drop policy if exists "Public can read active screens" on public.screens;

drop policy if exists "Admins manage screens" on public.screens;
create policy "Admins manage screens" on public.screens
  for all to authenticated using (true) with check (true);

drop policy if exists "Public can read active signage content" on public.slides;

drop policy if exists "Admins manage signage content" on public.slides;
create policy "Admins manage signage content" on public.slides
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
  join public.screens sc on sc.id = sl.screen_id
  where sc.id = input_screen_id and sc.is_active = true and sl.is_active = true
  order by sl.sort_order asc, sl.created_at asc;
$$;

revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

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
