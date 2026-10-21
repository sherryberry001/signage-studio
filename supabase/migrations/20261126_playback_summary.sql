-- Aggregate reported playback across the full selected period under the same
-- row-level access rules as the detailed playback history.
begin;

create or replace function public.team_playback_summary(
  input_from timestamptz,
  input_to timestamptz,
  input_screen_id uuid default null
)
returns table (
  slide_id uuid,
  content_title text,
  content_kind text,
  screen_count bigint,
  playback_count bigint,
  reported_seconds numeric
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
  if input_from is null or input_to is null or input_to <= input_from then
    raise exception 'Choose a valid playback reporting period';
  end if;
  if input_to - input_from > interval '366 days' then
    raise exception 'Playback reporting period cannot exceed 366 days';
  end if;

  return query
  select event.slide_id,
         event.content_title,
         event.content_kind,
         count(distinct event.screen_id),
         count(*)::bigint,
         coalesce(sum(greatest(0, extract(epoch from (
           least(event.ended_at, input_to) - greatest(event.started_at, input_from)
         )))), 0)::numeric
  from public.playback_events event
  where event.ended_at is not null
    and event.started_at < input_to
    and event.ended_at > input_from
    and (input_screen_id is null or event.screen_id = input_screen_id)
  group by event.slide_id, event.content_title, event.content_kind
  order by sum(greatest(0, extract(epoch from (
    least(event.ended_at, input_to) - greatest(event.started_at, input_from)
  )))) desc, event.content_title, event.slide_id
  limit 100;
end;
$$;
revoke all on function public.team_playback_summary(timestamptz, timestamptz, uuid) from public, anon;
grant execute on function public.team_playback_summary(timestamptz, timestamptz, uuid) to authenticated;

commit;
