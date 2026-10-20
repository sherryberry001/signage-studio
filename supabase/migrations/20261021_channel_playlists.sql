-- Let a channel sequence multiple reusable playlists, each with its own
-- priority and recurring/date schedule. Existing single-playlist channels are
-- migrated into the new membership table without changing their behavior.
begin;

create table if not exists public.channel_playlists (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels(id) on delete cascade,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  sort_order integer not null default 0,
  priority integer not null default 100 check (priority between 0 and 1000),
  active_from timestamptz,
  active_until timestamptz,
  weekdays smallint[],
  daily_start_time time,
  daily_end_time time,
  created_at timestamptz not null default now(),
  unique (channel_id, playlist_id),
  check (active_from is null or active_until is null or active_from < active_until),
  check (weekdays is null or (cardinality(weekdays) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[])),
  check ((daily_start_time is null) = (daily_end_time is null))
);

insert into public.channel_playlists(channel_id, playlist_id)
select ch.id, ch.playlist_id from public.channels ch
where ch.playlist_id is not null
on conflict (channel_id, playlist_id) do nothing;

create index if not exists channel_playlists_priority_idx on public.channel_playlists(channel_id, priority);
alter table public.channel_playlists enable row level security;
grant select, insert, update, delete on public.channel_playlists to authenticated;
drop policy if exists "Team members read channel playlists" on public.channel_playlists;
create policy "Team members read channel playlists" on public.channel_playlists
  for select to authenticated using (public.team_has_role(array['admin','editor','viewer']));
drop policy if exists "Editors manage channel playlists" on public.channel_playlists;
create policy "Editors manage channel playlists" on public.channel_playlists
  for all to authenticated
  using (public.team_has_role(array['admin','editor']))
  with check (public.team_has_role(array['admin','editor']));

create or replace function public.add_default_channel_playlist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.channel_playlists(channel_id, playlist_id)
  values (new.id, new.playlist_id)
  on conflict (channel_id, playlist_id) do nothing;
  return new;
end;
$$;
revoke all on function public.add_default_channel_playlist() from public;
drop trigger if exists add_default_channel_playlist on public.channels;
create trigger add_default_channel_playlist after insert on public.channels
  for each row execute function public.add_default_channel_playlist();

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
        'channel_playlist_priority', 2147483647,
        'forced', ts.forced_slide_id = sl.id and (ts.forced_until is null or ts.forced_until > now()),
        'forced_until', ts.forced_until,
        'layout_type', ts.layout_type,
        'layout_text', ts.layout_text
      ) as item
    from target_screen ts
    join public.slides sl on
      (sl.playlist_id = ts.playlist_id or (ts.playlist_id is null and sl.screen_id = ts.id))
    where ts.is_active and sl.is_active

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
        'channel_playlist_order', cp.sort_order,
        'channel_playlist_priority', cp.priority,
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
  )
  select item from player_items
  order by (item->>'channel_priority')::integer,
           (item->>'channel_playlist_priority')::integer,
           (item->>'channel_playlist_order')::integer,
           sort_order, created_at;
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

-- A player's live heartbeat may report any content from the screen's fallback
-- playlist or any playlist currently included in one of its assigned channels.
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
            join public.channel_playlists cp on cp.channel_id = ch.id
            where scs.screen_id = sc.id
              and sl.playlist_id = cp.playlist_id
          )
        )
    ));
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

create or replace function public.set_screen_cast(input_screen_id uuid, input_slide_id uuid, input_duration_minutes integer default 10)
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
  if not found then raise exception 'Screen was not found or is paused'; end if;
  if input_slide_id is not null and not exists (
    select 1 from public.slides sl
    where sl.id = input_slide_id and sl.is_active = true
      and (
        sl.playlist_id = target_playlist_id
        or (target_playlist_id is null and sl.screen_id = input_screen_id)
        or exists (
          select 1 from public.screen_channel_schedules scs
          join public.channels ch on ch.id = scs.channel_id
          join public.channel_playlists cp on cp.channel_id = ch.id
          where scs.screen_id = input_screen_id
            and sl.playlist_id = cp.playlist_id
        )
      )
  ) then raise exception 'The selected item is not active on this screen'; end if;
  update public.screens
  set forced_slide_id = input_slide_id,
      forced_until = case when input_slide_id is null then null else now() + make_interval(mins => input_duration_minutes) end
  where id = input_screen_id;
end;
$$;
revoke all on function public.set_screen_cast(uuid, uuid, integer) from public;
grant execute on function public.set_screen_cast(uuid, uuid, integer) to authenticated;

commit;
