-- Editors submit an immutable draft snapshot; admins approve or reject it.
begin;

create table if not exists public.screen_publication_requests (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  payload jsonb not null check (jsonb_typeof(payload) = 'array'),
  status text not null default 'pending'
    check (status in ('pending','approved','rejected','superseded')),
  requested_by uuid references auth.users(id) on delete set null,
  requested_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  review_note text
);
create index if not exists screen_publication_requests_screen_idx
  on public.screen_publication_requests(screen_id, requested_at desc);
create unique index if not exists one_pending_screen_publication_request
  on public.screen_publication_requests(screen_id) where status = 'pending';

alter table public.screen_publication_requests enable row level security;
revoke all on public.screen_publication_requests from public, anon, authenticated;
grant select (id, screen_id, status, requested_by, requested_at, reviewed_by, reviewed_at, review_note)
  on public.screen_publication_requests to authenticated;
drop policy if exists "Admins and request owners can read publication requests"
  on public.screen_publication_requests;
create policy "Admins and request owners can read publication requests"
  on public.screen_publication_requests for select to authenticated
  using (coalesce(public.current_team_role(), '') = 'admin' or requested_by = auth.uid());

create or replace function public.request_screen_publication(input_screen_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  request_id uuid;
  content_snapshot jsonb;
begin
  if coalesce(public.current_team_role(), '') <> 'editor' then
    raise exception 'Only editors can request publication approval' using errcode = '42501';
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

  update public.screen_publication_requests
  set status = 'superseded', reviewed_by = auth.uid(), reviewed_at = now(),
      review_note = 'Ersatt av en ny inskickad version.'
  where screen_id = input_screen_id and status = 'pending';

  insert into public.screen_publication_requests(screen_id, payload, requested_by)
  values (input_screen_id, content_snapshot, auth.uid())
  returning id into request_id;
  return request_id;
end;
$$;
revoke all on function public.request_screen_publication(uuid) from public, anon;
grant execute on function public.request_screen_publication(uuid) to authenticated;

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
  values (request_row.screen_id, 'sync_now');
  update public.screen_publication_requests
  set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), review_note = null
  where id = request_row.id;
  return next_revision;
end;
$$;
revoke all on function public.review_screen_publication(uuid, text, text) from public, anon;
grant execute on function public.review_screen_publication(uuid, text, text) to authenticated;

commit;
