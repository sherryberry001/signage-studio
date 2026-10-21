-- Duplicate a playlist and its ordered slide configuration atomically.
begin;

create or replace function public.duplicate_playlist_with_content(input_playlist_id uuid, input_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_playlist_id uuid;
  target_name text := btrim(coalesce(input_name, ''));
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can duplicate playlists' using errcode = '42501';
  end if;
  if char_length(target_name) not between 1 and 80 then
    raise exception 'Playlist name must be between 1 and 80 characters';
  end if;
  if not exists (select 1 from public.playlists where id = input_playlist_id) then
    raise exception 'Source playlist was not found';
  end if;

  insert into public.playlists(name) values (target_name)
  returning id into new_playlist_id;

  insert into public.slides(
    screen_id, playlist_id, kind, title, body, source_url, library_asset_id,
    integration_id, expires_at, duration_seconds, refresh_interval_seconds,
    sort_order, is_active, active_from, active_until, weekdays,
    daily_start_time, daily_end_time
  )
  select
    null, new_playlist_id, slide.kind, slide.title, slide.body, slide.source_url,
    slide.library_asset_id, slide.integration_id, slide.expires_at,
    slide.duration_seconds, slide.refresh_interval_seconds, slide.sort_order,
    slide.is_active, slide.active_from, slide.active_until, slide.weekdays,
    slide.daily_start_time, slide.daily_end_time
  from public.slides slide
  where slide.playlist_id = input_playlist_id
  order by slide.sort_order, slide.created_at, slide.id;

  return new_playlist_id;
end;
$$;
revoke all on function public.duplicate_playlist_with_content(uuid, text) from public, anon;
grant execute on function public.duplicate_playlist_with_content(uuid, text) to authenticated;

commit;
