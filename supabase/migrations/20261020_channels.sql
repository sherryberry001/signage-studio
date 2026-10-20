-- Named reusable channels map playlists to scheduled screens. The player receives
-- all assigned channel content plus schedule metadata so it can work offline.
begin;

create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (name)
);

create table if not exists public.screen_channel_schedules (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  channel_id uuid not null references public.channels(id) on delete cascade,
  priority integer not null default 100 check (priority between 0 and 1000),
  active_from timestamptz,
  active_until timestamptz,
  weekdays smallint[],
  daily_start_time time,
  daily_end_time time,
  created_at timestamptz not null default now(),
  unique (screen_id, channel_id),
  check (active_from is null or active_until is null or active_from < active_until),
  check (weekdays is null or (cardinality(weekdays) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[])),
  check ((daily_start_time is null) = (daily_end_time is null))
);

create index if not exists screen_channel_schedule_screen_idx on public.screen_channel_schedules(screen_id, priority);
create index if not exists screen_channel_schedule_channel_idx on public.screen_channel_schedules(channel_id);

grant select, insert, update, delete on public.channels, public.screen_channel_schedules to authenticated;
alter table public.channels enable row level security;
alter table public.screen_channel_schedules enable row level security;

drop policy if exists "Team members read channels" on public.channels;
drop policy if exists "Editors insert channels" on public.channels;
drop policy if exists "Editors update channels" on public.channels;
drop policy if exists "Editors delete channels" on public.channels;
create policy "Team members read channels" on public.channels
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']));
create policy "Editors insert channels" on public.channels
  for insert to authenticated with check (public.team_has_role(array['admin','editor']));
create policy "Editors update channels" on public.channels
  for update to authenticated using (public.team_has_role(array['admin','editor'])) with check (public.team_has_role(array['admin','editor']));
create policy "Editors delete channels" on public.channels
  for delete to authenticated using (public.team_has_role(array['admin','editor']));

drop policy if exists "Team members read channel schedules" on public.screen_channel_schedules;
drop policy if exists "Editors insert channel schedules" on public.screen_channel_schedules;
drop policy if exists "Editors update channel schedules" on public.screen_channel_schedules;
drop policy if exists "Editors delete channel schedules" on public.screen_channel_schedules;
create policy "Team members read channel schedules" on public.screen_channel_schedules
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']));
create policy "Editors insert channel schedules" on public.screen_channel_schedules
  for insert to authenticated with check (public.team_has_role(array['admin','editor']));
create policy "Editors update channel schedules" on public.screen_channel_schedules
  for update to authenticated using (public.team_has_role(array['admin','editor'])) with check (public.team_has_role(array['admin','editor']));
create policy "Editors delete channel schedules" on public.screen_channel_schedules
  for delete to authenticated using (public.team_has_role(array['admin','editor']));

-- Extend direct content control so it can target content in any assigned channel.
create or replace function public.set_screen_forced_slide(input_screen_id uuid, input_slide_id uuid)
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
  select playlist_id into target_playlist_id
    from public.screens where id = input_screen_id and is_active = true for update;
  if not found then
    raise exception 'Screen was not found or is paused';
  end if;
  if input_slide_id is not null and not exists (
    select 1 from public.slides sl
    where sl.id = input_slide_id and sl.is_active = true
      and (
        sl.playlist_id = target_playlist_id
        or (target_playlist_id is null and sl.screen_id = input_screen_id)
        or exists (
          select 1 from public.screen_channel_schedules scs
          join public.channels ch on ch.id = scs.channel_id
          where scs.screen_id = input_screen_id and sl.playlist_id = ch.playlist_id
        )
      )
  ) then
    raise exception 'The selected item is not active on this screen';
  end if;
  update public.screens set forced_slide_id = input_slide_id where id = input_screen_id;
end;
$$;
revoke all on function public.set_screen_forced_slide(uuid, uuid) from public;
grant execute on function public.set_screen_forced_slide(uuid, uuid) to authenticated;

-- Return complete JSON player items with channel schedule metadata. The player
-- selects the active channel locally, including while its network is offline.
drop function if exists public.player_playlist(uuid);
create function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with target_screen as (
    select id, playlist_id, forced_slide_id, is_active
    from public.screens where id = input_screen_id
  ),
  player_items as (
    select sl.sort_order, sl.created_at,
      to_jsonb(sl) || jsonb_build_object(
        'channel_id', null::uuid,
        'channel_priority', 2147483647,
        'forced', ts.forced_slide_id = sl.id
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
        'forced', ts.forced_slide_id = sl.id
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

-- A heartbeat may refer to any item from the screen's fallback playlist or an
-- assigned channel, while still rejecting items from unrelated screens.
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
          or (sc.playlist_id is null and sl.screen_id = sc.id)
          or exists (
            select 1 from public.screen_channel_schedules scs
            join public.channels ch on ch.id = scs.channel_id
            where scs.screen_id = sc.id and sl.playlist_id = ch.playlist_id
          )
        )
    ));
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

commit;
