-- A screen may run its own playlist in the secondary ticker/side-panel zone.
-- Both playlists are sent to the player together for offline schedule selection.
begin;

alter table public.screens
  add column if not exists zone_playlist_id uuid references public.playlists(id) on delete set null;

create index if not exists screens_zone_playlist_idx on public.screens(zone_playlist_id)
  where zone_playlist_id is not null;

create or replace function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with target_screen as (
    select id, playlist_id, zone_playlist_id, forced_slide_id, forced_until,
           is_active, layout_type, layout_text
    from public.screens where id = input_screen_id
  ),
  player_items as (
    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', null::uuid,
        'channel_priority', 2147483647,
        'channel_playlist_priority', 2147483647,
        'channel_playlist_order', 0,
        'forced', ts.forced_slide_id = sl.id and (ts.forced_until is null or ts.forced_until > now()),
        'forced_until', ts.forced_until,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.slides sl on
      (sl.playlist_id = ts.playlist_id or (ts.playlist_id is null and sl.screen_id = ts.id))
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_until <= now() or ts.forced_slide_id = sl.id)

    union all

    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', ch.id,
        'channel_name', ch.name,
        'channel_priority', scs.priority,
        'channel_active_from', scs.active_from,
        'channel_active_until', scs.active_until,
        'channel_weekdays', scs.weekdays,
        'channel_daily_start_time', scs.daily_start_time,
        'channel_daily_end_time', scs.daily_end_time,
        'channel_playlist_id', cp.playlist_id,
        'channel_playlist_priority', cp.priority,
        'channel_playlist_order', cp.sort_order,
        'channel_playlist_active_from', cp.active_from,
        'channel_playlist_active_until', cp.active_until,
        'channel_playlist_weekdays', cp.weekdays,
        'channel_playlist_daily_start_time', cp.daily_start_time,
        'channel_playlist_daily_end_time', cp.daily_end_time,
        'forced', ts.forced_slide_id = sl.id and (ts.forced_until is null or ts.forced_until > now()),
        'forced_until', ts.forced_until,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.screen_channel_schedules scs on scs.screen_id = ts.id
    join public.channels ch on ch.id = scs.channel_id
    join public.channel_playlists cp on cp.channel_id = ch.id
    join public.slides sl on sl.playlist_id = cp.playlist_id
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_until <= now() or ts.forced_slide_id = sl.id)

    union all

    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'layout_zone', 'secondary',
        'channel_id', null::uuid,
        'channel_priority', 2147483646,
        'channel_playlist_priority', 2147483647,
        'channel_playlist_order', 0,
        'forced', false,
        'forced_until', null,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.slides sl on sl.playlist_id = ts.zone_playlist_id
    where ts.is_active and sl.is_active
  )
  select item from player_items
  order by (item->>'channel_priority')::integer,
           (item->>'channel_playlist_priority')::integer,
           (item->>'channel_playlist_order')::integer,
           sort_order, created_at;
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
        and (
          sl.playlist_id = sc.playlist_id
          or sl.playlist_id = sc.zone_playlist_id
          or (sc.playlist_id is null and sl.screen_id = sc.id)
          or exists (
            select 1 from public.screen_channel_schedules scs
            join public.channels ch on ch.id = scs.channel_id
            join public.channel_playlists cp on cp.channel_id = ch.id
            where scs.screen_id = sc.id and sl.playlist_id = cp.playlist_id
          )
        )
    ));
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

commit;
