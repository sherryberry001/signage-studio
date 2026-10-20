-- Simple native multi-zone screen layouts: one primary zone plus an optional
-- live ticker or side panel. The player receives settings with its cached items.
begin;

alter table public.screens
  add column if not exists layout_type text not null default 'single',
  add column if not exists layout_text text not null default '';

alter table public.screens drop constraint if exists screens_layout_type_check;
alter table public.screens add constraint screens_layout_type_check
  check (layout_type in ('single', 'bottom_ticker', 'side_panel'));
alter table public.screens drop constraint if exists screens_layout_text_check;
alter table public.screens add constraint screens_layout_text_check
  check (char_length(layout_text) <= 500);

create or replace function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with target_screen as (
    select id, playlist_id, forced_slide_id, is_active, layout_type, layout_text
    from public.screens where id = input_screen_id
  ),
  player_items as (
    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', null::uuid,
        'channel_priority', 2147483647,
        'forced', ts.forced_slide_id = sl.id,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.slides sl on
      (sl.playlist_id = ts.playlist_id or (ts.playlist_id is null and sl.screen_id = ts.id))
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_slide_id = sl.id)

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
        'forced', ts.forced_slide_id = sl.id,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.screen_channel_schedules scs on scs.screen_id = ts.id
    join public.channels ch on ch.id = scs.channel_id
    join public.slides sl on sl.playlist_id = ch.playlist_id
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_slide_id = sl.id)
  )
  select item from player_items
  order by (item->>'channel_priority')::integer, sort_order, created_at;
$$;

revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

commit;
