-- Reorder every playlist within one channel as a single, validated operation.
begin;

create or replace function public.reorder_channel_playlists(
  input_channel_id uuid,
  input_playlist_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_count integer;
  requested_count integer;
  distinct_count integer;
begin
  if coalesce(public.current_team_role(), '') not in ('admin', 'editor') then
    raise exception 'Only admins and editors can reorder channel playlists' using errcode = '42501';
  end if;
  if input_playlist_ids is null or cardinality(input_playlist_ids) = 0 or cardinality(input_playlist_ids) > 200 then
    raise exception 'Choose between 1 and 200 channel playlists';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(input_channel_id::text, 930));
  perform 1 from public.channels where id = input_channel_id for update;
  if not found then raise exception 'Channel was not found'; end if;

  requested_count := cardinality(input_playlist_ids);
  select count(distinct requested.playlist_id)::integer
    into distinct_count
    from unnest(input_playlist_ids) as requested(playlist_id);
  if distinct_count <> requested_count then
    raise exception 'Channel playlist order contains duplicates';
  end if;

  select count(*)::integer into current_count
    from public.channel_playlists
    where channel_id = input_channel_id;
  if current_count <> requested_count
    or exists (
      select 1 from public.channel_playlists membership
      where membership.channel_id = input_channel_id
        and not (membership.playlist_id = any(input_playlist_ids))
    )
    or exists (
      select 1 from unnest(input_playlist_ids) as requested(playlist_id)
      where not exists (
        select 1 from public.channel_playlists membership
        where membership.channel_id = input_channel_id
          and membership.playlist_id = requested.playlist_id
      )
    ) then
    raise exception 'Channel playlist order is stale; reload and try again';
  end if;

  update public.channel_playlists membership
  set sort_order = requested.ordinality::integer - 1
  from unnest(input_playlist_ids) with ordinality as requested(playlist_id, ordinality)
  where membership.channel_id = input_channel_id
    and membership.playlist_id = requested.playlist_id;
end;
$$;

revoke all on function public.reorder_channel_playlists(uuid, uuid[]) from public, anon;
grant execute on function public.reorder_channel_playlists(uuid, uuid[]) to authenticated;

commit;
