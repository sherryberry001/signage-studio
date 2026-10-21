-- Bound reported playback to the last known heartbeat and start a fresh
-- playback segment when a player reconnects after a real offline gap.
begin;

create or replace function public.capture_playback_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  prior_end timestamptz;
begin
  if old.current_slide_id is not distinct from new.current_slide_id then
    return new;
  end if;

  prior_end := case
    when old.last_seen_at is not null and old.last_seen_at < now() - interval '45 seconds'
      then old.last_seen_at
    else now()
  end;

  update public.playback_events
  set ended_at = greatest(started_at, prior_end)
  where screen_id = new.id and ended_at is null;

  if new.current_slide_id is not null
     and new.is_active
     and new.activated_at is not null then
    insert into public.playback_events(
      screen_id, screen_name, screen_group_id, slide_id, content_title, content_kind
    ) values (
      new.id, new.name, new.group_id, new.current_slide_id,
      coalesce(nullif(new.current_title, ''), 'Innehåll'), new.current_kind
    );
  end if;

  return new;
end;
$$;
revoke all on function public.capture_playback_transition() from public, anon, authenticated;

create or replace function public.record_playback_after_offline_gap()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.last_seen_at is null
     or old.last_seen_at >= now() - interval '45 seconds'
     or new.current_slide_id is distinct from old.current_slide_id
     or new.current_slide_id is null
     or not new.is_active
     or new.activated_at is null then
    return new;
  end if;

  -- The screen health cron may already have closed the row. This also handles
  -- reconnects that happen before the next cron tick.
  update public.playback_events
  set ended_at = greatest(started_at, least(old.last_seen_at, now()))
  where screen_id = new.id and ended_at is null;

  insert into public.playback_events(
    screen_id, screen_name, screen_group_id, slide_id, content_title, content_kind
  ) values (
    new.id, new.name, new.group_id, new.current_slide_id,
    coalesce(nullif(new.current_title, ''), 'Innehåll'), new.current_kind
  );

  return new;
end;
$$;
revoke all on function public.record_playback_after_offline_gap() from public, anon, authenticated;
drop trigger if exists record_playback_after_offline_gap on public.screens;
create trigger record_playback_after_offline_gap
  after update of last_seen_at on public.screens
  for each row execute function public.record_playback_after_offline_gap();

create or replace function public.record_screen_health_transitions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  screen_row record;
  previous_status text;
  next_status text;
  inserted_count integer := 0;
begin
  for screen_row in
    select id, name, group_id, last_seen_at, activated_at
    from public.screens
    where is_active and activated_at is not null
  loop
    perform pg_advisory_xact_lock(hashtextextended(screen_row.id::text, 0));
    select event.status into previous_status
    from public.screen_health_events event
    where event.screen_id = screen_row.id
    order by event.observed_at desc, event.id desc
    limit 1;

    next_status := case
      when screen_row.last_seen_at >= now() - interval '45 seconds' then 'online'
      else 'offline'
    end;

    if next_status = 'offline' and screen_row.last_seen_at is not null then
      update public.playback_events
      set ended_at = greatest(started_at, least(screen_row.last_seen_at, now()))
      where screen_id = screen_row.id and ended_at is null;
    end if;

    if previous_status is distinct from next_status then
      insert into public.screen_health_events(
        screen_id, screen_name, screen_group_id, status, observed_at, last_seen_at
      ) values (
        screen_row.id, screen_row.name, screen_row.group_id,
        next_status, now(), screen_row.last_seen_at
      );
      inserted_count := inserted_count + 1;
    end if;
  end loop;
  return inserted_count;
end;
$$;
revoke all on function public.record_screen_health_transitions() from public, anon, authenticated;

commit;
