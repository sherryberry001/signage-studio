-- Keep retired screen profiles and their history while removing them from
-- day-to-day fleet views. Archiving always pauses the player profile.
alter table public.screens
  add column if not exists archived_at timestamptz;

alter table public.screens
  drop constraint if exists screens_archived_profiles_are_paused_check;
alter table public.screens
  add constraint screens_archived_profiles_are_paused_check
  check (archived_at is null or is_active = false);

create index if not exists screens_archived_idx
  on public.screens(archived_at desc)
  where archived_at is not null;
