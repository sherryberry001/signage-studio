-- Bind an Android TV's pseudonymous, stable device identity to one screen row.
-- A reused pairing code on the same TV resolves to the existing screen profile.
begin;

alter table public.screens add column if not exists device_identity text;
create unique index if not exists screens_device_identity_active_idx
  on public.screens(device_identity)
  where is_active = true and device_identity is not null;

create or replace function public.activate_screen(input_code text, input_device_identity text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.screens%rowtype;
  existing_id uuid;
begin
  if input_device_identity is null or input_device_identity !~ '^device:[a-f0-9]{64}$' then
    raise exception 'Invalid player identity';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(input_device_identity, 0));

  select * into target
  from public.screens
  where pair_code = upper(trim(input_code)) and is_active = true
  for update;
  if not found then return null; end if;

  select id into existing_id
  from public.screens
  where device_identity = input_device_identity and is_active = true
  for update;

  if existing_id is not null and existing_id <> target.id then
    if target.activated_at is null
       and target.playlist_id is null
       and target.forced_slide_id is null
       and not exists (select 1 from public.slides where screen_id = target.id)
       and not exists (select 1 from public.screen_channel_schedules where screen_id = target.id) then
      update public.screens set is_active = false, pair_code = null where id = target.id;
      return existing_id;
    end if;
    raise exception 'This TV is already paired to another screen profile';
  end if;
  if target.device_identity is not null and target.device_identity <> input_device_identity then
    raise exception 'This screen profile belongs to another TV';
  end if;

  update public.screens
  set pair_code = null,
      activated_at = coalesce(activated_at, now()),
      device_identity = input_device_identity
  where id = target.id;
  return target.id;
end;
$$;
revoke all on function public.activate_screen(text, text) from public;
grant execute on function public.activate_screen(text, text) to anon, authenticated;

create or replace function public.player_bind_device_identity(input_screen_id uuid, input_device_identity text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  target_identity text;
  existing_id uuid;
begin
  if input_device_identity is null or input_device_identity !~ '^device:[a-f0-9]{64}$' then
    raise exception 'Invalid player identity';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(input_device_identity, 0));

  select device_identity into target_identity
  from public.screens
  where id = input_screen_id and is_active = true
  for update;
  if not found then return null; end if;

  select id into existing_id
  from public.screens
  where device_identity = input_device_identity and is_active = true
  for update;
  if existing_id is not null and existing_id <> input_screen_id then
    raise exception 'This TV is already paired to another screen profile';
  end if;
  if target_identity is not null and target_identity <> input_device_identity then
    raise exception 'This screen profile belongs to another TV';
  end if;

  update public.screens set device_identity = input_device_identity where id = input_screen_id;
  return input_screen_id;
end;
$$;
revoke all on function public.player_bind_device_identity(uuid, text) from public;
grant execute on function public.player_bind_device_identity(uuid, text) to anon, authenticated;

commit;
