-- Let admins tune the proportions of the existing two-zone layouts per screen.
begin;

alter table public.screens
  add column if not exists layout_split_percent integer not null default 72,
  add column if not exists layout_ticker_percent integer not null default 16;

alter table public.screens drop constraint if exists screens_layout_split_percent_check;
alter table public.screens add constraint screens_layout_split_percent_check
  check (layout_split_percent between 55 and 85);
alter table public.screens drop constraint if exists screens_layout_ticker_percent_check;
alter table public.screens add constraint screens_layout_ticker_percent_check
  check (layout_ticker_percent between 10 and 25);

create or replace function public.player_screen_config(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'operating_weekdays', to_jsonb(sc.operating_weekdays),
    'operating_start_time', sc.operating_start_time,
    'operating_end_time', sc.operating_end_time,
    'playback_mode', sc.playback_mode,
    'autostart_enabled', sc.autostart_enabled,
    'is_active', sc.is_active
  )
  from public.screens sc
  where sc.id = input_screen_id;
$$;
revoke all on function public.player_screen_config(uuid) from public;
grant execute on function public.player_screen_config(uuid) to anon, authenticated;

create or replace function public.publish_screen_content(input_screen_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  next_revision integer;
  content_snapshot jsonb;
  split_percent integer;
  ticker_percent integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can publish screen content' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(input_screen_id::text, 71));
  select sc.layout_split_percent, sc.layout_ticker_percent
    into split_percent, ticker_percent
  from public.screens sc
  where sc.id = input_screen_id and sc.is_active = true
  for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;

  select coalesce(jsonb_agg(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(item, '{forced}', 'false'::jsonb, true),
          '{forced_until}', 'null'::jsonb, true
        ),
        '{layout_split_percent}', to_jsonb(split_percent), true
      ),
      '{layout_ticker_percent}', to_jsonb(ticker_percent), true
    )
    order by (item->>'channel_priority')::integer,
      (item->>'channel_playlist_priority')::integer,
      (item->>'channel_playlist_order')::integer,
      (item->>'sort_order')::integer,
      (item->>'created_at')::timestamptz
  ), '[]'::jsonb)
  into content_snapshot
  from public.player_playlist_source(input_screen_id) as current_item(item)
  where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now();

  select coalesce(max(revision), 0) + 1 into next_revision
  from public.screen_publications where screen_id = input_screen_id;
  insert into public.screen_publications(screen_id, revision, payload, published_by)
  values (input_screen_id, next_revision, content_snapshot, auth.uid());
  insert into public.screen_commands(screen_id, command)
  values (input_screen_id, 'sync_now')
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return next_revision;
end;
$$;
revoke all on function public.publish_screen_content(uuid) from public, anon;
grant execute on function public.publish_screen_content(uuid) to authenticated;

commit;
