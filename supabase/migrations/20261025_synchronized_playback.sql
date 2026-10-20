-- Align playback timelines across screens that share the same active channel
-- or playlist. Independent remains the default for existing installations.
begin;

alter table public.screens
  add column if not exists playback_mode text not null default 'independent';

do $$ begin
  alter table public.screens add constraint screens_playback_mode_check
    check (playback_mode in ('independent', 'sync'));
exception when duplicate_object then null;
end $$;

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
    'playback_mode', sc.playback_mode
  )
  from public.screens sc
  where sc.id = input_screen_id and sc.is_active;
$$;
revoke all on function public.player_screen_config(uuid) from public;
grant execute on function public.player_screen_config(uuid) to anon, authenticated;

commit;
