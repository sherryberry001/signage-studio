-- Allow admins/editors to request an immediate fresh TV screenshot and track
-- completion through the existing durable player-command queue.
begin;

alter table public.screen_commands
  drop constraint if exists screen_commands_command_check;
alter table public.screen_commands
  add constraint screen_commands_command_check
  check (command in ('sync_now', 'restart_player', 'capture_preview'));

create or replace function public.queue_player_command(input_screen_id uuid, input_command text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  command_id uuid;
begin
  if public.current_team_role() is distinct from 'admin'
     and public.current_team_role() is distinct from 'editor' then
    raise exception 'Only admins and editors can operate players' using errcode = '42501';
  end if;
  if input_command not in ('sync_now', 'restart_player', 'capture_preview') then
    raise exception 'Unsupported player command';
  end if;
  if not exists (select 1 from public.screens where id = input_screen_id and is_active = true) then
    raise exception 'Screen was not found or is paused';
  end if;

  insert into public.screen_commands(screen_id, command)
  values (input_screen_id, input_command)
  returning id into command_id;
  return command_id;
end;
$$;
revoke all on function public.queue_player_command(uuid, text) from public;
grant execute on function public.queue_player_command(uuid, text) to authenticated;

commit;
