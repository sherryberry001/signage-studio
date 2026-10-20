-- Durable remote commands for native players. Admin/editor users can enqueue
-- refresh/restart operations; the TV can claim only commands for its own UUID.
begin;

create table if not exists public.screen_commands (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  command text not null check (command in ('sync_now', 'restart_player')),
  status text not null default 'pending' check (status in ('pending', 'running', 'completed', 'failed')),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  error_message text
);

create index if not exists screen_commands_pending_idx
  on public.screen_commands(screen_id, created_at) where status in ('pending', 'running');

alter table public.screen_commands enable row level security;
revoke all on public.screen_commands from anon, authenticated;
grant select on public.screen_commands to authenticated;

drop policy if exists "Team can read screen command history" on public.screen_commands;
create policy "Team can read screen command history" on public.screen_commands
  for select to authenticated
  using (public.team_has_role(array['admin', 'editor', 'viewer']));

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
  if input_command not in ('sync_now', 'restart_player') then
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

create or replace function public.player_claim_command(input_screen_id uuid)
returns table(command_id uuid, command text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.screens where id = input_screen_id and is_active = true) then
    return;
  end if;

  -- Requeue commands whose player disappeared after claiming them.
  update public.screen_commands
  set status = 'pending', started_at = null
  where screen_id = input_screen_id and status = 'running'
    and started_at < now() - interval '2 minutes';

  return query
  with candidate as (
    select sc.id
    from public.screen_commands sc
    where sc.screen_id = input_screen_id and sc.status = 'pending'
    order by sc.created_at, sc.id
    for update skip locked
    limit 1
  )
  update public.screen_commands sc
  set status = 'running', started_at = now()
  from candidate
  where sc.id = candidate.id
  returning sc.id, sc.command;
end;
$$;
revoke all on function public.player_claim_command(uuid) from public;
grant execute on function public.player_claim_command(uuid) to anon, authenticated;

create or replace function public.player_complete_command(
  input_screen_id uuid,
  input_command_id uuid,
  input_error text default null
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screen_commands
  set status = case when nullif(input_error, '') is null then 'completed' else 'failed' end,
      completed_at = now(),
      error_message = left(nullif(input_error, ''), 500)
  where id = input_command_id and screen_id = input_screen_id and status = 'running';
$$;
revoke all on function public.player_complete_command(uuid, uuid, text) from public;
grant execute on function public.player_complete_command(uuid, uuid, text) to anon, authenticated;

commit;
