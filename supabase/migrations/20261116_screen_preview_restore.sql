-- Restore a published screen snapshot as a new revision, preserving history.
begin;

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
  values (input_screen_id, 'sync_now');

  return next_revision;
end;
$$;
revoke all on function public.restore_screen_publication(uuid, integer) from public, anon;
grant execute on function public.restore_screen_publication(uuid, integer) to authenticated;

commit;
