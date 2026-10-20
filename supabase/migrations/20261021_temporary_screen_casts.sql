-- Temporary screen casts override the current programme, then expire back to it.
begin;

alter table public.screens
  add column if not exists forced_until timestamptz;

create or replace function public.set_screen_cast(
  input_screen_id uuid,
  input_slide_id uuid,
  input_duration_minutes integer default 10
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_playlist_id uuid;
begin
  if public.current_team_role() is distinct from 'admin'
     and public.current_team_role() is distinct from 'editor' then
    raise exception 'Only admins and editors can control screen content' using errcode = '42501';
  end if;
  if input_duration_minutes not between 1 and 1440 then
    raise exception 'Cast duration must be between 1 and 1440 minutes';
  end if;

  select playlist_id into target_playlist_id
  from public.screens where id = input_screen_id and is_active = true for update;
  if not found then
    raise exception 'Screen was not found or is paused';
  end if;
  if input_slide_id is not null and not exists (
    select 1 from public.slides sl
    where sl.id = input_slide_id and sl.is_active = true
      and (sl.playlist_id = target_playlist_id or (target_playlist_id is null and sl.screen_id = input_screen_id))
  ) then
    raise exception 'The selected item is not active on this screen';
  end if;

  update public.screens
  set forced_slide_id = input_slide_id,
      forced_until = case when input_slide_id is null then null else now() + make_interval(mins => input_duration_minutes) end
  where id = input_screen_id;
end;
$$;
revoke all on function public.set_screen_cast(uuid, uuid, integer) from public;
grant execute on function public.set_screen_cast(uuid, uuid, integer) to authenticated;

-- Keep existing screens on the ordinary playlist after their cast expires.
create or replace function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with target_screen as (
    select id, playlist_id, forced_slide_id, forced_until, is_active, layout_type, layout_text
    from public.screens where id = input_screen_id
  ),
  player_items as (
    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', null::uuid,
        'channel_priority', 2147483647,
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
        'forced', ts.forced_slide_id = sl.id and (ts.forced_until is null or ts.forced_until > now()),
        'forced_until', ts.forced_until,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.screen_channel_schedules scs on scs.screen_id = ts.id
    join public.channels ch on ch.id = scs.channel_id
    join public.slides sl on sl.playlist_id = ch.playlist_id
    where ts.is_active and sl.is_active
      and (ts.forced_slide_id is null or ts.forced_until <= now() or ts.forced_slide_id = sl.id)
  )
  select item from player_items
  order by (item->>'channel_priority')::integer, sort_order, created_at;
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

commit;
