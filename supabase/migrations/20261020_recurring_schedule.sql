-- Add recurring weekly display windows while preserving existing one-off dates.
begin;

alter table public.slides add column if not exists weekdays smallint[];
alter table public.slides add column if not exists daily_start_time time;
alter table public.slides add column if not exists daily_end_time time;

alter table public.slides drop constraint if exists slides_weekdays_check;
alter table public.slides add constraint slides_weekdays_check
  check (weekdays is null or (cardinality(weekdays) between 1 and 7 and weekdays <@ array[1,2,3,4,5,6,7]::smallint[]));

alter table public.slides drop constraint if exists slides_daily_window_check;
alter table public.slides add constraint slides_daily_window_check
  check ((daily_start_time is null) = (daily_end_time is null));

create index if not exists slides_recurring_schedule_idx on public.slides(active_from, active_until, daily_start_time, daily_end_time);

commit;
