-- Persist team-wide thresholds for in-app screen and feed operations alerts.
begin;

create table if not exists public.team_operational_settings (
  id boolean primary key default true check (id),
  offline_alert_after_minutes integer not null default 3
    check (offline_alert_after_minutes between 1 and 60),
  command_alert_after_minutes integer not null default 2
    check (command_alert_after_minutes between 1 and 30),
  feed_error_window_minutes integer not null default 15
    check (feed_error_window_minutes between 5 and 240),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
insert into public.team_operational_settings(id) values (true)
on conflict (id) do nothing;

alter table public.team_operational_settings enable row level security;
revoke all on public.team_operational_settings from public, anon, authenticated;
grant select, update on public.team_operational_settings to authenticated;
drop policy if exists "Team can read operational alert settings" on public.team_operational_settings;
create policy "Team can read operational alert settings"
  on public.team_operational_settings for select to authenticated
  using (public.current_team_role() is not null);
drop policy if exists "Admins update operational alert settings" on public.team_operational_settings;
create policy "Admins update operational alert settings"
  on public.team_operational_settings for update to authenticated
  using (public.team_has_role(array['admin']))
  with check (public.team_has_role(array['admin']));

commit;
