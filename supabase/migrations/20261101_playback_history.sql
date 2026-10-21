-- Record each screen's reported content transition and retain reports after deletion.
begin;

create table if not exists public.playback_events (
  id bigint generated always as identity primary key,
  screen_id uuid references public.screens(id) on delete set null,
  screen_name text not null,
  screen_group_id uuid references public.screen_groups(id) on delete set null,
  slide_id uuid,
  content_title text not null,
  content_kind text,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create index if not exists playback_events_started_idx
  on public.playback_events(started_at desc, id desc);
create index if not exists playback_events_screen_idx
  on public.playback_events(screen_id, started_at desc);
create index if not exists playback_events_content_idx
  on public.playback_events(content_title, started_at desc);

alter table public.playback_events enable row level security;
revoke all on public.playback_events from anon, authenticated;
grant select on public.playback_events to authenticated;
drop policy if exists "Team can read playback history" on public.playback_events;
create policy "Team can read playback history" on public.playback_events
  for select to authenticated
  using (
    public.team_has_role(array['admin', 'editor', 'viewer'])
    or (screen_id is not null and public.user_can_access_screen(screen_id))
    or (screen_group_id is not null and public.user_can_access_group(screen_group_id))
  );

create or replace function public.capture_playback_transition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.current_slide_id is not distinct from new.current_slide_id then
    return new;
  end if;

  update public.playback_events
    set ended_at = now()
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
drop trigger if exists capture_playback_transition on public.screens;
create trigger capture_playback_transition
  after update of current_slide_id on public.screens
  for each row execute function public.capture_playback_transition();

commit;
