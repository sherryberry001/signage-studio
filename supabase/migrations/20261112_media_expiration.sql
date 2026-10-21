-- Keep library-item expiration with every playlist reference and enforce it
-- server-side while returning schedules to players.
begin;

alter table public.media_library add column if not exists expires_at timestamptz;
alter table public.slides add column if not exists expires_at timestamptz;
create index if not exists media_library_expires_at_idx
  on public.media_library(expires_at) where expires_at is not null;
create index if not exists slides_expires_at_idx
  on public.slides(expires_at) where expires_at is not null;

create or replace function public.sync_media_library_references()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.slides
  set kind = new.kind,
      title = new.title,
      body = new.body,
      source_url = new.source_url,
      integration_id = new.integration_id,
      refresh_interval_seconds = new.refresh_interval_seconds,
      expires_at = new.expires_at
  where library_asset_id = new.id;
  return new;
end;
$$;
drop trigger if exists sync_media_library_references on public.media_library;
create trigger sync_media_library_references
  after update of kind, title, body, source_url, integration_id, refresh_interval_seconds, expires_at
  on public.media_library
  for each row execute function public.sync_media_library_references();

drop trigger if exists activity_slides_update on public.slides;
create trigger activity_slides_update after update of screen_id, playlist_id, integration_id, kind, title, body, source_url,
  library_asset_id, duration_seconds, refresh_interval_seconds, expires_at, sort_order, is_active,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.slides for each row execute function public.capture_activity_log();
drop trigger if exists activity_media_library_update on public.media_library;
create trigger activity_media_library_update after update of kind, title, body, source_url,
  integration_id, duration_seconds, refresh_interval_seconds, expires_at, tags
  on public.media_library for each row execute function public.capture_activity_log();

drop function if exists public.player_playlist_source(uuid);
alter function public.player_playlist(uuid) rename to player_playlist_source;
revoke all on function public.player_playlist_source(uuid) from public, anon, authenticated;
create function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  select player_item.item
  from public.player_playlist_source(input_screen_id) as player_item(item)
  where player_item.item->>'expires_at' is null
     or (player_item.item->>'expires_at')::timestamptz > now();
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

commit;
