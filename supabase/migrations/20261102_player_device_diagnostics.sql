-- Store non-sensitive player/device diagnostics for fleet health visibility.
begin;

alter table public.screens
  add column if not exists player_version text,
  add column if not exists device_model text,
  add column if not exists android_version text,
  add column if not exists display_size text,
  add column if not exists network_type text,
  add column if not exists device_updated_at timestamptz;

create or replace function public.player_report_device_info(
  input_screen_id uuid,
  input_player_version text,
  input_device_model text,
  input_android_version text,
  input_display_size text,
  input_network_type text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screens
  set player_version = left(nullif(input_player_version, ''), 40),
      device_model = left(nullif(input_device_model, ''), 100),
      android_version = left(nullif(input_android_version, ''), 40),
      display_size = left(nullif(input_display_size, ''), 40),
      network_type = left(nullif(input_network_type, ''), 24),
      device_updated_at = now()
  where id = input_screen_id and is_active and activated_at is not null;
$$;
revoke all on function public.player_report_device_info(uuid, text, text, text, text, text) from public;
grant execute on function public.player_report_device_info(uuid, text, text, text, text, text) to anon, authenticated;

commit;
