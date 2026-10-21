-- Scheduled and media-backed broadcasts. Future items are sent to offline
-- capable players early, with their start/end window embedded in the cache.
begin;

alter table public.screen_broadcasts
  add column if not exists kind text not null default 'text',
  add column if not exists source_url text,
  add column if not exists duration_seconds integer not null default 60;
alter table public.screen_broadcasts drop constraint if exists screen_broadcasts_kind_check;
alter table public.screen_broadcasts add constraint screen_broadcasts_kind_check
  check (kind in ('text','image','video'));
alter table public.screen_broadcasts drop constraint if exists screen_broadcasts_duration_seconds_check;
alter table public.screen_broadcasts add constraint screen_broadcasts_duration_seconds_check
  check (duration_seconds between 5 and 600);

drop function if exists public.create_screen_broadcast(uuid[], text, text, integer);
create or replace function public.create_screen_broadcast(
  input_screen_ids uuid[],
  input_title text,
  input_body text,
  input_duration_minutes integer default 10,
  input_start_at timestamptz default now(),
  input_asset_id uuid default null,
  input_duration_seconds integer default 60
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
  broadcast_start timestamptz;
  broadcast_end timestamptz;
  broadcast_kind text := 'text';
  broadcast_source_url text;
  asset_expiration timestamptz;
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
  if input_start_at is null or input_start_at < now() - interval '2 minutes'
     or input_start_at > now() + interval '90 days' then
    raise exception 'Choose a start time between now and 90 days from now';
  end if;
  broadcast_start := greatest(input_start_at, now());
  broadcast_end := broadcast_start + make_interval(mins => input_duration_minutes);
  if input_duration_seconds is null or input_duration_seconds not between 5 and 600 then
    raise exception 'Content display duration must be between 5 and 600 seconds';
  end if;
  if nullif(btrim(input_title), '') is null or char_length(btrim(input_title)) > 120 then
    raise exception 'Enter a title of up to 120 characters';
  end if;
  if char_length(coalesce(input_body, '')) > 1200 then
    raise exception 'Message must be no longer than 1200 characters';
  end if;
  if input_asset_id is null and nullif(btrim(input_body), '') is null then
    raise exception 'Enter a message or choose an image/video from the media library';
  end if;

  if input_asset_id is not null then
    select asset.kind, asset.source_url, asset.expires_at
      into broadcast_kind, broadcast_source_url, asset_expiration
    from public.media_library asset
    where asset.id = input_asset_id;
    if not found or broadcast_kind not in ('image','video')
       or broadcast_source_url is null
       or broadcast_source_url !~* '^https?://' then
      raise exception 'Choose an available image or video from the media library';
    end if;
    if asset_expiration is not null and asset_expiration <= broadcast_end then
      raise exception 'The selected media expires before the broadcast ends';
    end if;
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

  insert into public.screen_broadcasts(title, body, kind, source_url, duration_seconds, starts_at, ends_at, created_by)
  values (btrim(input_title), coalesce(input_body, ''), broadcast_kind, broadcast_source_url,
    input_duration_seconds, broadcast_start, broadcast_end, auth.uid())
  returning id into new_broadcast_id;
  insert into public.slides(broadcast_id, kind, title, body, source_url, duration_seconds, sort_order, is_active, expires_at)
  values (new_broadcast_id, broadcast_kind, btrim(input_title), coalesce(input_body, ''),
    broadcast_source_url, input_duration_seconds, 0, true, broadcast_end)
  returning id into new_slide_id;
  update public.screen_broadcasts set slide_id = new_slide_id where id = new_broadcast_id;

  -- A later overlapping programme takes over at its start. Before that time,
  -- the older programme remains eligible, including in an offline cache.
  update public.screen_broadcast_targets target
  set superseded_at = broadcast_start
  from public.screen_broadcasts older
  where target.broadcast_id = older.id
    and target.screen_id = any(input_screen_ids)
    and (target.superseded_at is null or target.superseded_at > broadcast_start)
    and older.id <> new_broadcast_id
    and older.cancelled_at is null
    and older.starts_at < broadcast_start
    and older.ends_at > broadcast_start;
  insert into public.screen_broadcast_targets(broadcast_id, screen_id)
  select new_broadcast_id, selected.screen_id
  from (select distinct unnest(input_screen_ids) as screen_id) selected;
  insert into public.screen_commands(screen_id, command)
  select distinct selected.screen_id, 'sync_now'
  from unnest(input_screen_ids) as selected(screen_id)
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return new_broadcast_id;
end;
$$;
revoke all on function public.create_screen_broadcast(uuid[], text, text, integer, timestamptz, uuid, integer) from public, anon;
grant execute on function public.create_screen_broadcast(uuid[], text, text, integer, timestamptz, uuid, integer) to authenticated;

create or replace function public.cancel_screen_broadcast(input_broadcast_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  target_count integer;
  broadcast_start timestamptz;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can cancel announcements' using errcode = '42501';
  end if;
  select starts_at into broadcast_start
  from public.screen_broadcasts
  where id = input_broadcast_id and cancelled_at is null and ends_at > now()
  for update;
  if not found then raise exception 'The announcement is no longer active'; end if;
  update public.screen_broadcasts
  set cancelled_at = now(),
      ends_at = greatest(now(), starts_at + interval '1 second')
  where id = input_broadcast_id;

  if broadcast_start > now() then
    update public.screen_broadcast_targets older_target
    set superseded_at = (
      select min(candidate.starts_at)
      from public.screen_broadcast_targets candidate_target
      join public.screen_broadcasts candidate on candidate.id = candidate_target.broadcast_id
      join public.screen_broadcasts older on older.id = older_target.broadcast_id
      where candidate_target.screen_id = older_target.screen_id
        and candidate.id <> input_broadcast_id
        and candidate.cancelled_at is null
        and candidate.starts_at > older.starts_at
        and candidate.starts_at < older.ends_at
        and candidate.ends_at > now()
        and (candidate_target.superseded_at is null or candidate_target.superseded_at > now())
        and candidate.starts_at > now()
    )
    from public.screen_broadcasts older
    where older_target.broadcast_id = older.id
      and older_target.superseded_at = broadcast_start
      and older.id <> input_broadcast_id
      and older.cancelled_at is null;
  end if;

  -- If another announcement is already live on the same screen, the older
  -- item must stay superseded now. Otherwise let it resume at the next
  -- scheduled announcement, or remove the boundary if none remains.
  if broadcast_start > now() then
    update public.screen_broadcast_targets older_target
    set superseded_at = now()
    from public.screen_broadcasts older
    where older_target.broadcast_id = older.id
      and older_target.superseded_at = broadcast_start
      and older.id <> input_broadcast_id
      and older.cancelled_at is null
      and exists (
        select 1
        from public.screen_broadcast_targets active_target
        join public.screen_broadcasts active_broadcast on active_broadcast.id = active_target.broadcast_id
        where active_target.screen_id = older_target.screen_id
          and active_broadcast.id <> input_broadcast_id
          and active_broadcast.cancelled_at is null
          and active_broadcast.starts_at <= now()
          and active_broadcast.ends_at > now()
          and active_broadcast.starts_at > older.starts_at
          and active_broadcast.starts_at < older.ends_at
          and (active_target.superseded_at is null or active_target.superseded_at > now())
      );
  end if;

  select count(*) into target_count
  from public.screen_broadcast_targets
  where broadcast_id = input_broadcast_id
    and (superseded_at is null or superseded_at > now());
  insert into public.screen_commands(screen_id, command)
  select screen_id, 'sync_now'
  from public.screen_broadcast_targets
  where broadcast_id = input_broadcast_id
    and (superseded_at is null or superseded_at > now())
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return target_count;
end;
$$;
revoke all on function public.cancel_screen_broadcast(uuid) from public, anon;
grant execute on function public.cancel_screen_broadcast(uuid) to authenticated;

create or replace function public.player_publication_snapshot(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with player_screen as (
    select id, layout_type, layout_text, player_version
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
  ), broadcast_items as (
    select jsonb_build_object(
      'id', broadcast.slide_id,
      'broadcast_id', broadcast.id,
      'kind', broadcast.kind,
      'title', broadcast.title,
      'body', broadcast.body,
      'source_url', broadcast.source_url,
      'duration_seconds', broadcast.duration_seconds,
      'sort_order', 0,
      'created_at', broadcast.created_at,
      'is_active', true,
      'forced', true,
      'forced_from', broadcast.starts_at,
      'forced_until', case when target.superseded_at is not null and target.superseded_at < broadcast.ends_at then target.superseded_at else broadcast.ends_at end,
      'expires_at', case when target.superseded_at is not null and target.superseded_at < broadcast.ends_at then target.superseded_at else broadcast.ends_at end,
      'layout_type', player_screen.layout_type,
      'layout_text', player_screen.layout_text
    ) as item,
    row_number() over (order by broadcast.starts_at, broadcast.created_at, broadcast.id)::bigint as item_position
    from player_screen
    join public.screen_broadcast_targets target on target.screen_id = player_screen.id
    join public.screen_broadcasts broadcast on broadcast.id = target.broadcast_id
    where broadcast.cancelled_at is null
      and (target.superseded_at is null or target.superseded_at > now())
      and broadcast.ends_at > now()
      and (broadcast.starts_at <= now() or player_screen.player_version ~ '^([2-9]|[1-9][0-9]+)[.]'
        or player_screen.player_version ~ '^1[.](1[9]|[2-9][0-9])[.]')
    order by broadcast.starts_at, broadcast.created_at, broadcast.id
    limit 50
  ), all_items as (
    select item, item_position, is_forced from published_items
    union all
    select item, item_position, is_forced from existing_casts
    union all
    select item, item_position, true as is_forced from broadcast_items
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
      select 1 from jsonb_array_elements(coalesce(
        public.player_publication_snapshot(input_screen_id)->'items', '[]'::jsonb
      )) published(item)
      where published.item->>'id' = input_current_slide_id::text
    ));
end;
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

commit;
