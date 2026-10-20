-- Recurring screen operating hours. The player remains connected and reports
-- heartbeat while blanking the display outside the configured hours.
begin;

alter table public.screens
  add column if not exists operating_weekdays smallint[],
  add column if not exists operating_start_time time,
  add column if not exists operating_end_time time;

do $$ begin
  alter table public.screens add constraint screens_operating_weekdays_check
    check (operating_weekdays is null or (cardinality(operating_weekdays) between 1 and 7 and operating_weekdays <@ array[1,2,3,4,5,6,7]::smallint[]));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.screens add constraint screens_operating_hours_pair_check
    check ((operating_start_time is null) = (operating_end_time is null));
exception when duplicate_object then null;
end $$;

do $$ begin
  alter table public.screens add constraint screens_operating_hours_unequal_check
    check (operating_start_time is null or operating_start_time <> operating_end_time);
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
    'operating_end_time', sc.operating_end_time
  )
  from public.screens sc
  where sc.id = input_screen_id and sc.is_active;
$$;
revoke all on function public.player_screen_config(uuid) from public;
grant execute on function public.player_screen_config(uuid) to anon, authenticated;

commit;
