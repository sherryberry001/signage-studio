-- Deliver one time-limited announcement to several screens without changing
-- their saved playlists or published revisions.
begin;

create table if not exists public.screen_broadcasts (
  id uuid primary key default gen_random_uuid(),
  slide_id uuid unique,
  title text not null check (char_length(btrim(title)) between 1 and 120),
  body text not null check (char_length(btrim(body)) between 1 and 1200),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  cancelled_at timestamptz,
  check (starts_at < ends_at)
);
alter table public.screen_broadcasts
  add column if not exists slide_id uuid;
alter table public.screen_broadcasts alter column slide_id drop not null;
alter table public.screen_broadcasts drop constraint if exists screen_broadcasts_slide_id_fkey;
create unique index if not exists screen_broadcasts_slide_id_idx
  on public.screen_broadcasts(slide_id) where slide_id is not null;

create table if not exists public.screen_broadcast_targets (
  broadcast_id uuid not null references public.screen_broadcasts(id) on delete cascade,
  screen_id uuid not null references public.screens(id) on delete cascade,
  superseded_at timestamptz,
  primary key (broadcast_id, screen_id)
);
alter table public.screen_broadcast_targets
  add column if not exists superseded_at timestamptz;
alter table public.slides add column if not exists broadcast_id uuid;
alter table public.slides drop constraint if exists slides_content_owner_check;
alter table public.slides add constraint slides_content_owner_check check (
  (screen_id is not null)::integer
  + (playlist_id is not null)::integer
  + (broadcast_id is not null)::integer = 1
);
alter table public.slides drop constraint if exists slides_broadcast_id_fkey;
alter table public.slides add constraint slides_broadcast_id_fkey
  foreign key (broadcast_id) references public.screen_broadcasts(id) on delete cascade;
create index if not exists screen_broadcast_targets_screen_idx
  on public.screen_broadcast_targets(screen_id, broadcast_id);
create index if not exists screen_broadcasts_active_idx
  on public.screen_broadcasts(starts_at, ends_at) where cancelled_at is null;

alter table public.screen_broadcasts enable row level security;
alter table public.screen_broadcast_targets enable row level security;
revoke all on public.screen_broadcasts, public.screen_broadcast_targets from public, anon, authenticated;
grant select on public.screen_broadcasts, public.screen_broadcast_targets to authenticated;

drop policy if exists "Team can read accessible broadcasts" on public.screen_broadcasts;
create policy "Team can read accessible broadcasts" on public.screen_broadcasts
  for select to authenticated using (
    public.team_has_role(array['admin','editor','viewer'])
    or exists (
      select 1 from public.screen_broadcast_targets target
      where target.broadcast_id = screen_broadcasts.id
        and public.user_can_access_screen(target.screen_id)
    )
  );
drop policy if exists "Team can read accessible broadcast targets" on public.screen_broadcast_targets;
create policy "Team can read accessible broadcast targets" on public.screen_broadcast_targets
  for select to authenticated using (
    public.team_has_role(array['admin','editor','viewer'])
    or public.user_can_access_screen(screen_id)
  );

create or replace function public.create_screen_broadcast(
  input_screen_ids uuid[],
  input_title text,
  input_body text,
  input_duration_minutes integer default 10
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_broadcast_id uuid;
  new_slide_id uuid;
  requested_count integer;
  active_count integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can send announcements' using errcode = '42501';
  end if;
  if input_screen_ids is null then raise exception 'Choose at least one screen'; end if;
  select count(distinct screen_id) into requested_count
  from unnest(input_screen_ids) as selected(screen_id);
  if requested_count < 1 or requested_count > 100 then
    raise exception 'Choose between 1 and 100 screens';
  end if;
  if input_duration_minutes is null or input_duration_minutes not between 1 and 1440 then
    raise exception 'Announcement duration must be between 1 and 1440 minutes';
  end if;
  if nullif(btrim(input_title), '') is null or char_length(btrim(input_title)) > 120 then
    raise exception 'Enter a title of up to 120 characters';
  end if;
  if nullif(btrim(input_body), '') is null or char_length(btrim(input_body)) > 1200 then
    raise exception 'Enter a message of up to 1200 characters';
  end if;

  select count(*) into active_count
  from public.screens screen_row
  where screen_row.id = any(input_screen_ids)
    and screen_row.is_active
    and screen_row.activated_at is not null
    and (public.team_has_role(array['admin','editor']) or public.user_can_access_screen(screen_row.id));
  if active_count <> requested_count then
    raise exception 'One or more selected screens are paused, unavailable, or outside your access';
  end if;

  insert into public.screen_broadcasts(title, body, ends_at, created_by)
  values (btrim(input_title), btrim(input_body), now() + make_interval(mins => input_duration_minutes), auth.uid())
  returning id into new_broadcast_id;
  insert into public.slides(broadcast_id, kind, title, body, duration_seconds, sort_order, is_active, expires_at)
  values (new_broadcast_id, 'text', btrim(input_title), btrim(input_body), 15, 0, true,
    now() + make_interval(mins => input_duration_minutes))
  returning id into new_slide_id;
  update public.screen_broadcasts set slide_id = new_slide_id where id = new_broadcast_id;
  update public.screen_broadcast_targets target
  set superseded_at = now()
  from public.screen_broadcasts older
  where target.broadcast_id = older.id
    and target.screen_id = any(input_screen_ids)
    and target.superseded_at is null
    and older.id <> new_broadcast_id
    and older.cancelled_at is null
    and older.starts_at <= now()
    and older.ends_at > now();
  insert into public.screen_broadcast_targets(broadcast_id, screen_id)
  select new_broadcast_id, target_id
  from (select distinct selected.screen_id as target_id from unnest(input_screen_ids) as selected(screen_id)) targets;
  insert into public.screen_commands(screen_id, command)
  select distinct selected.screen_id, 'sync_now'
  from unnest(input_screen_ids) as selected(screen_id)
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return new_broadcast_id;
end;
$$;
revoke all on function public.create_screen_broadcast(uuid[], text, text, integer) from public, anon;
grant execute on function public.create_screen_broadcast(uuid[], text, text, integer) to authenticated;

create or replace function public.cancel_screen_broadcast(input_broadcast_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target_count integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can cancel announcements' using errcode = '42501';
  end if;
  update public.screen_broadcasts
  set cancelled_at = now(), ends_at = now()
  where id = input_broadcast_id and cancelled_at is null and ends_at > now();
  if not found then raise exception 'The announcement is no longer active'; end if;

  select count(*) into target_count
  from public.screen_broadcast_targets
  where broadcast_id = input_broadcast_id and superseded_at is null;
  insert into public.screen_commands(screen_id, command)
  select screen_id, 'sync_now'
  from public.screen_broadcast_targets
  where broadcast_id = input_broadcast_id and superseded_at is null
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return target_count;
end;
$$;
revoke all on function public.cancel_screen_broadcast(uuid) from public, anon;
grant execute on function public.cancel_screen_broadcast(uuid) to authenticated;

-- The announcement rides alongside the last published playlist snapshot.
-- Its expiration is embedded so the player also returns to normal content offline.
create or replace function public.player_publication_snapshot(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with player_screen as (
    select id, layout_type, layout_text
    from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ), latest_publication as (
    select publication.revision, publication.payload
    from public.screen_publications publication
    join player_screen on player_screen.id = publication.screen_id
    order by publication.revision desc
    limit 1
  ), published_items as (
    select item, item_position, false as is_forced
    from latest_publication publication
    cross join lateral jsonb_array_elements(publication.payload) with ordinality as snapshot(item, item_position)
    where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now()
  ), existing_casts as (
    select live.item, live.ordinality + 1 as item_position, true as is_forced
    from player_screen
    cross join lateral public.player_playlist_source(player_screen.id) with ordinality as live(item, ordinality)
    where live.item->>'forced' = 'true'
      and (live.item->>'forced_until' is null or (live.item->>'forced_until')::timestamptz > now())
      and (live.item->>'expires_at' is null or (live.item->>'expires_at')::timestamptz > now())
  ), active_broadcast as (
    select jsonb_build_object(
      'id', broadcast.slide_id,
      'broadcast_id', broadcast.id,
      'kind', 'text',
      'title', broadcast.title,
      'body', broadcast.body,
      'duration_seconds', 15,
      'sort_order', 0,
      'created_at', broadcast.created_at,
      'is_active', true,
      'forced', true,
      'forced_until', broadcast.ends_at,
      'expires_at', broadcast.ends_at,
      'layout_type', player_screen.layout_type,
      'layout_text', player_screen.layout_text
    ) as item
    from player_screen
    join public.screen_broadcast_targets target on target.screen_id = player_screen.id
    join public.screen_broadcasts broadcast on broadcast.id = target.broadcast_id
    where broadcast.cancelled_at is null
      and target.superseded_at is null
      and broadcast.starts_at <= now()
      and broadcast.ends_at > now()
    order by broadcast.created_at desc, broadcast.id
    limit 1
  ), all_items as (
    select item, item_position, is_forced from published_items
    union all
    select item, item_position, is_forced from existing_casts
    union all
    select item, 0 as item_position, true as is_forced from active_broadcast
  )
  select jsonb_build_object(
    'revision', latest_publication.revision,
    'items', coalesce((
      select jsonb_agg(all_items.item order by all_items.is_forced desc, all_items.item_position)
      from all_items
    ), '[]'::jsonb)
  )
  from latest_publication
  where exists (select 1 from player_screen);
$$;
revoke all on function public.player_publication_snapshot(uuid) from public;
grant execute on function public.player_publication_snapshot(uuid) to anon, authenticated;

-- Heartbeat validation accepts a slide only when it is in the screen's
-- published snapshot or active temporary overlay, including broadcasts.
create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.screens screen_row
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where screen_row.id = input_screen_id
    and screen_row.is_active
    and (input_current_slide_id is null or exists (
      select 1
      from jsonb_array_elements(coalesce(
        public.player_publication_snapshot(input_screen_id)->'items', '[]'::jsonb
      )) published(item)
      where published.item->>'id' = input_current_slide_id::text
    ));
end;
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

commit;
