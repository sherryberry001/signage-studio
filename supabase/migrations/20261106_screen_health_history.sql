-- Record screen availability transitions independently of the admin browser.
begin;

create extension if not exists pg_cron with schema pg_catalog;

create table if not exists public.screen_health_events (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  screen_name text not null,
  screen_group_id uuid references public.screen_groups(id) on delete set null,
  status text not null check (status in ('online', 'offline')),
  observed_at timestamptz not null default now(),
  last_seen_at timestamptz
);
create index if not exists screen_health_events_history_idx
  on public.screen_health_events(screen_id, observed_at desc);
create index if not exists screen_health_events_group_idx
  on public.screen_health_events(screen_group_id, observed_at desc);

alter table public.screen_health_events enable row level security;
revoke all on public.screen_health_events from public, anon, authenticated;
grant select on public.screen_health_events to authenticated;
drop policy if exists "Team can read screen health history" on public.screen_health_events;
create policy "Team can read screen health history" on public.screen_health_events
  for select to authenticated
  using (
    public.team_has_role(array['admin', 'editor', 'viewer'])
    or public.user_can_access_screen(screen_id)
    or (screen_group_id is not null and public.user_can_access_group(screen_group_id))
  );

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

    if previous_status is distinct from next_status then
      insert into public.screen_health_events(
        screen_id, screen_name, screen_group_id, status, observed_at, last_seen_at
      ) values (
        screen_row.id, screen_row.name, screen_row.group_id, next_status, now(), screen_row.last_seen_at
      );
      inserted_count := inserted_count + 1;
    end if;
  end loop;
  return inserted_count;
end;
$$;
revoke all on function public.record_screen_health_transitions() from public, anon, authenticated;

do $$
declare
  existing_job bigint;
begin
  for existing_job in select jobid from cron.job where jobname = 'signage-screen-health-observer' loop
    perform cron.unschedule(existing_job);
  end loop;
  perform cron.schedule(
    'signage-screen-health-observer',
    '* * * * *',
    'select public.record_screen_health_transitions();'
  );
end;
$$;

commit;
