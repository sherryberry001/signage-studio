-- Let the player atomically read a published revision and acknowledge that it
-- has stored that revision locally. This is delivery evidence, not proof that
-- the physical panel is powered or visible.
begin;

alter table public.screens
  add column if not exists applied_revision integer,
  add column if not exists applied_revision_at timestamptz;

create or replace function public.player_publication_snapshot(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with player_screen as (
    select id from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ), latest_publication as (
    select publication.revision, publication.payload
    from public.screen_publications publication
    join player_screen on player_screen.id = publication.screen_id
    order by publication.revision desc
    limit 1
  ), published_items as (
    select item, item_position, false as is_forced
    from latest_publication publication
    cross join lateral jsonb_array_elements(publication.payload) with ordinality as snapshot(item, item_position)
    where item->>'expires_at' is null
      or (item->>'expires_at')::timestamptz > now()
  ), forced_items as (
    select live.item, live.ordinality as item_position, true as is_forced
    from player_screen
    cross join lateral public.player_playlist_source(player_screen.id) with ordinality as live(item, ordinality)
    where live.item->>'forced' = 'true'
      and (live.item->>'forced_until' is null or (live.item->>'forced_until')::timestamptz > now())
      and (live.item->>'expires_at' is null or (live.item->>'expires_at')::timestamptz > now())
  ), all_items as (
    select * from published_items
    union all
    select * from forced_items
  )
  select jsonb_build_object(
    'revision', latest_publication.revision,
    'items', coalesce((
      select jsonb_agg(all_items.item order by all_items.is_forced desc, all_items.item_position)
      from all_items
    ), '[]'::jsonb)
  )
  from latest_publication
  where exists (select 1 from player_screen);
$$;

create or replace function public.player_ack_screen_publication(
  input_screen_id uuid,
  input_revision integer
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if input_revision is null or input_revision < 0 then return false; end if;
  if not exists (
    select 1 from public.screens
    where id = input_screen_id and is_active and activated_at is not null
  ) then return false; end if;
  if not exists (
    select 1 from public.screen_publications
    where screen_id = input_screen_id and revision = input_revision
  ) then return false; end if;

  update public.screens
  set applied_revision = input_revision,
      applied_revision_at = now()
  where id = input_screen_id
    and (applied_revision is null or applied_revision < input_revision);
  return true;
end;
$$;

revoke all on function public.player_publication_snapshot(uuid) from public;
revoke all on function public.player_ack_screen_publication(uuid, integer) from public;
grant execute on function public.player_publication_snapshot(uuid) to anon, authenticated;
grant execute on function public.player_ack_screen_publication(uuid, integer) to anon, authenticated;

commit;
