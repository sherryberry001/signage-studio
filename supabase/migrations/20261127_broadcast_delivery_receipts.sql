-- Summarize which target screens actually reported displaying each broadcast.
-- SECURITY INVOKER keeps the underlying screen and playback RLS policies active.
begin;

create or replace function public.team_broadcast_delivery_summary(input_broadcast_ids uuid[])
returns table (
  broadcast_id uuid,
  screen_id uuid,
  first_shown_at timestamptz,
  last_shown_at timestamptz,
  playback_count bigint
)
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;
  if input_broadcast_ids is null or cardinality(input_broadcast_ids) > 100 then
    raise exception 'Choose no more than 100 broadcasts';
  end if;

  return query
  select broadcast.id,
         target.screen_id,
         min(event_row.started_at) filter (where event_row.id is not null),
         max(event_row.started_at) filter (where event_row.id is not null),
         count(event_row.id)::bigint
  from public.screen_broadcasts broadcast
  join public.screen_broadcast_targets target on target.broadcast_id = broadcast.id
  left join public.playback_events event_row
    on event_row.screen_id = target.screen_id
    and event_row.slide_id = broadcast.slide_id
    and event_row.started_at >= broadcast.starts_at
    and event_row.started_at < broadcast.ends_at
  where broadcast.id = any(input_broadcast_ids)
  group by broadcast.id, target.screen_id
  order by broadcast.id, target.screen_id;
end;
$$;
revoke all on function public.team_broadcast_delivery_summary(uuid[]) from public, anon;
grant execute on function public.team_broadcast_delivery_summary(uuid[]) to authenticated;

commit;
