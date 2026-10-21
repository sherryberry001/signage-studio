-- Atomically replace a playlist's complete slide order after validating membership.
begin;

create or replace function public.reorder_playlist_slides(
  input_playlist_id uuid,
  input_slide_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  expected_count integer;
  requested_count integer;
  unique_count integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin', 'editor') then
    raise exception 'Only admins and editors can reorder playlist items' using errcode = '42501';
  end if;
  if input_playlist_id is null or input_slide_ids is null then
    raise exception 'Playlist and ordered slide IDs are required';
  end if;

  perform id from public.playlists where id = input_playlist_id for update;
  if not found then raise exception 'Playlist was not found'; end if;

  select count(*) into expected_count from public.slides where playlist_id = input_playlist_id;
  requested_count := cardinality(input_slide_ids);
  select count(distinct slide_id) into unique_count from unnest(input_slide_ids) as requested(slide_id);
  if requested_count <> expected_count or unique_count <> expected_count then
    raise exception 'The order must contain every playlist item exactly once';
  end if;
  if exists (
    select 1 from unnest(input_slide_ids) as requested(slide_id)
    where not exists (
      select 1 from public.slides slide
      where slide.id = requested.slide_id and slide.playlist_id = input_playlist_id
    )
  ) then
    raise exception 'The order contains an item outside this playlist';
  end if;

  update public.slides slide
  set sort_order = ordered.ordinality::integer * 10
  from unnest(input_slide_ids) with ordinality as ordered(slide_id, ordinality)
  where slide.id = ordered.slide_id and slide.playlist_id = input_playlist_id;
end;
$$;
revoke all on function public.reorder_playlist_slides(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_playlist_slides(uuid, uuid[]) to authenticated;

commit;
