-- Relaunch the signage player after a TV reboot by default, with an admin
-- control to disable boot launch for an individual screen.
begin;

alter table public.screens
  add column if not exists autostart_enabled boolean not null default true;

create or replace function public.player_screen_config(input_screen_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'operating_weekdays', to_jsonb(sc.operating_weekdays),
    'operating_start_time', sc.operating_start_time,
    'operating_end_time', sc.operating_end_time,
    'playback_mode', sc.playback_mode,
    'autostart_enabled', sc.autostart_enabled,
    'is_active', sc.is_active
  )
  from public.screens sc
  where sc.id = input_screen_id;
$$;
revoke all on function public.player_screen_config(uuid) from public;
grant execute on function public.player_screen_config(uuid) to anon, authenticated;

commit;
