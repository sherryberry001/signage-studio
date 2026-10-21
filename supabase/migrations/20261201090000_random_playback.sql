-- Allow a screen to select active playlist items in random order.
begin;

alter table public.screens
  drop constraint if exists screens_playback_mode_check;

alter table public.screens
  add constraint screens_playback_mode_check
  check (playback_mode in ('independent', 'sync', 'random'));

commit;
