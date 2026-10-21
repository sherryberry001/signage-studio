-- Keep one waiting command of each type per screen. A currently running
-- command may still have one pending successor (for example, publish during sync).
begin;

lock table public.screen_commands in share row exclusive mode;

with ranked as (
  select id, row_number() over (
    partition by screen_id, command
    order by created_at, id
  ) as queue_rank
  from public.screen_commands
  where status = 'pending'
)
update public.screen_commands command_row
set status = 'failed',
    completed_at = now(),
    error_message = 'Duplicate pending command superseded during queue deduplication.'
from ranked
where command_row.id = ranked.id and ranked.queue_rank > 1;

create unique index if not exists screen_commands_one_pending_per_type_idx
  on public.screen_commands(screen_id, command) where status = 'pending';

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
  on conflict (screen_id, command) where status = 'pending'
  do update set command = excluded.command
  returning id into command_id;
  return command_id;
end;
$$;
revoke all on function public.queue_player_command(uuid, text) from public;
grant execute on function public.queue_player_command(uuid, text) to authenticated;

create or replace function public.publish_screen_content(input_screen_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  next_revision integer;
  content_snapshot jsonb;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can publish screen content' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(input_screen_id::text, 71));
  perform 1 from public.screens where id = input_screen_id and is_active = true for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;

  select coalesce(jsonb_agg(
    jsonb_set(jsonb_set(item, '{forced}', 'false'::jsonb, true), '{forced_until}', 'null'::jsonb, true)
    order by (item->>'channel_priority')::integer,
      (item->>'channel_playlist_priority')::integer,
      (item->>'channel_playlist_order')::integer,
      (item->>'sort_order')::integer,
      (item->>'created_at')::timestamptz
  ), '[]'::jsonb)
  into content_snapshot
  from public.player_playlist_source(input_screen_id) as current_item(item)
  where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now();

  select coalesce(max(revision), 0) + 1 into next_revision
  from public.screen_publications where screen_id = input_screen_id;
  insert into public.screen_publications(screen_id, revision, payload, published_by)
  values (input_screen_id, next_revision, content_snapshot, auth.uid());
  insert into public.screen_commands(screen_id, command)
  values (input_screen_id, 'sync_now')
  on conflict (screen_id, command) where status = 'pending' do nothing;
  return next_revision;
end;
$$;
revoke all on function public.publish_screen_content(uuid) from public, anon;
grant execute on function public.publish_screen_content(uuid) to authenticated;

create or replace function public.restore_screen_publication(
  input_screen_id uuid,
  input_revision integer
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  next_revision integer;
  restored_payload jsonb;
begin
  if coalesce(public.current_team_role(), '') not in ('admin','editor') then
    raise exception 'Only admins and editors can restore screen content' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(input_screen_id::text, 71));
  perform 1 from public.screens where id = input_screen_id and is_active = true for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;

  select payload into restored_payload
  from public.screen_publications
  where screen_id = input_screen_id and revision = input_revision;
  if not found then raise exception 'Publication version was not found'; end if;

  select coalesce(max(revision), 0) + 1 into next_revision
  from public.screen_publications where screen_id = input_screen_id;

  insert into public.screen_publications(screen_id, revision, payload, published_by)
  values (input_screen_id, next_revision, restored_payload, auth.uid());
  insert into public.screen_commands(screen_id, command)
  values (input_screen_id, 'sync_now')
  on conflict (screen_id, command) where status = 'pending' do nothing;

  return next_revision;
end;
$$;
revoke all on function public.restore_screen_publication(uuid, integer) from public, anon;
grant execute on function public.restore_screen_publication(uuid, integer) to authenticated;

create or replace function public.review_screen_publication(
  input_request_id uuid,
  input_decision text,
  input_review_note text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.screen_publication_requests%rowtype;
  next_revision integer;
begin
  if coalesce(public.current_team_role(), '') <> 'admin' then
    raise exception 'Only admins can review publication requests' using errcode = '42501';
  end if;
  if input_decision not in ('approve','reject') then
    raise exception 'Decision must be approve or reject';
  end if;

  select * into request_row from public.screen_publication_requests
  where id = input_request_id and status = 'pending' for update;
  if not found then raise exception 'Pending publication request was not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended(request_row.screen_id::text, 71));
  perform 1 from public.screens where id = request_row.screen_id and is_active = true for update;
  if not found then raise exception 'Screen was not found or is paused'; end if;

  if input_decision = 'reject' then
    update public.screen_publication_requests
    set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(),
        review_note = left(nullif(trim(input_review_note), ''), 500)
    where id = request_row.id;
    return null;
  end if;

  select coalesce(max(revision), 0) + 1 into next_revision
  from public.screen_publications where screen_id = request_row.screen_id;
  insert into public.screen_publications(screen_id, revision, payload, published_by)
  values (request_row.screen_id, next_revision, request_row.payload, auth.uid());
  insert into public.screen_commands(screen_id, command)
  values (request_row.screen_id, 'sync_now')
  on conflict (screen_id, command) where status = 'pending' do nothing;
  update public.screen_publication_requests
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = null
  where id = request_row.id;
  return next_revision;
end;
$$;
revoke all on function public.review_screen_publication(uuid, text, text) from public, anon;
grant execute on function public.review_screen_publication(uuid, text, text) to authenticated;

commit;
