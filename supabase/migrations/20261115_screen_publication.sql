-- Publish a versioned per-screen content snapshot. Player polling reads only
-- the last published snapshot; edits in the admin tables remain drafts.
begin;

create table if not exists public.screen_publications (
  id uuid primary key default gen_random_uuid(),
  screen_id uuid not null references public.screens(id) on delete cascade,
  revision integer not null check (revision >= 0),
  payload jsonb not null check (jsonb_typeof(payload) = 'array'),
  published_at timestamptz not null default now(),
  published_by uuid references auth.users(id) on delete set null,
  unique (screen_id, revision)
);
create index if not exists screen_publications_latest_idx
  on public.screen_publications(screen_id, revision desc);

alter table public.screen_publications enable row level security;
revoke all on public.screen_publications from public, anon, authenticated;
grant select on public.screen_publications to authenticated;
drop policy if exists "Team can read screen publications" on public.screen_publications;
create policy "Team can read screen publications" on public.screen_publications
  for select to authenticated using (
    public.team_has_role(array['admin','editor','viewer'])
    or public.user_can_access_screen(screen_id)
  );

create or replace function public.initialize_screen_publication()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.screen_publications(screen_id, revision, payload, published_at)
  values (new.id, 0, '[]'::jsonb, coalesce(new.activated_at, new.created_at));
  return new;
end;
$$;
revoke all on function public.initialize_screen_publication() from public, anon, authenticated;
drop trigger if exists initialize_screen_publication on public.screens;
create trigger initialize_screen_publication after insert on public.screens
  for each row execute function public.initialize_screen_publication();

-- Existing screens start with exactly the content they were already showing.
insert into public.screen_publications(screen_id, revision, payload, published_at)
select screen_row.id, 0, live.payload, coalesce(screen_row.activated_at, screen_row.created_at)
from public.screens screen_row
cross join lateral (
  select coalesce(jsonb_agg(item order by
    (item->>'channel_priority')::integer,
    (item->>'channel_playlist_priority')::integer,
    (item->>'channel_playlist_order')::integer,
    (item->>'sort_order')::integer,
    (item->>'created_at')::timestamptz
  ), '[]'::jsonb) as payload
  from public.player_playlist_source(screen_row.id) as current_item(item)
  where item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now()
) live
on conflict (screen_id, revision) do nothing;

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
  values (input_screen_id, 'sync_now');
  return next_revision;
end;
$$;
revoke all on function public.publish_screen_content(uuid) from public, anon;
grant execute on function public.publish_screen_content(uuid) to authenticated;

create or replace function public.player_playlist(input_screen_id uuid)
returns setof jsonb
language sql
stable
security definer
set search_path = public
as $$
  with latest_publication as (
    select publication.payload
    from public.screen_publications publication
    join public.screens screen_row on screen_row.id = publication.screen_id and screen_row.is_active
    where publication.screen_id = input_screen_id
    order by publication.revision desc
    limit 1
  ), player_items as (
    select item, item_position, false as is_forced
    from latest_publication publication
    cross join lateral jsonb_array_elements(publication.payload) with ordinality as snapshot(item, item_position)
    where item->>'expires_at' is null
      or (item->>'expires_at')::timestamptz > now()

    union all

    select item, item_position, true as is_forced
    from public.player_playlist_source(input_screen_id) with ordinality as live(item, item_position)
    where item->>'forced' = 'true'
      and (item->>'forced_until' is null or (item->>'forced_until')::timestamptz > now())
      and (item->>'expires_at' is null or (item->>'expires_at')::timestamptz > now())
  )
  select item from player_items order by is_forced desc, item_position;
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

-- Resolve integration credentials from the published media snapshot, so edits
-- to a feed connection cannot silently change the TV before publication.
create or replace function public.player_get_integration_config(input_screen_id uuid, input_slide_id uuid)
returns table(provider text, endpoint_url text, display_token text)
language plpgsql
security definer
set search_path = public
as $$
declare
  integration_id_value uuid;
begin
  if not exists (select 1 from public.screens where id = input_screen_id and is_active and activated_at is not null) then
    return;
  end if;
  select (candidate.item->>'integration_id')::uuid into integration_id_value
  from (
    select live.item, 1 as source_priority
    from public.player_playlist_source(input_screen_id) as live(item)
    where live.item->>'id' = input_slide_id::text
      and live.item->>'forced' = 'true'
    union all
    select published.item, 2 as source_priority
    from public.screen_publications publication
    cross join lateral jsonb_array_elements(publication.payload) as published(item)
    where publication.screen_id = input_screen_id
      and publication.revision = (select max(current.revision) from public.screen_publications current where current.screen_id = input_screen_id)
      and published.item->>'id' = input_slide_id::text
      and published.item->>'kind' = 'feed'
      and published.item->>'integration_id' is not null
  ) candidate
  where candidate.item->>'kind' = 'feed' and candidate.item->>'integration_id' is not null
  order by candidate.source_priority
  limit 1;
  if integration_id_value is null then return; end if;
  return query select integration.provider, integration.endpoint_url, secret.display_token
  from public.signage_integrations integration
  join public.signage_integration_secrets secret on secret.integration_id = integration.id
  where integration.id = integration_id_value;
end;
$$;
revoke all on function public.player_get_integration_config(uuid, uuid) from public;
grant execute on function public.player_get_integration_config(uuid, uuid) to anon, authenticated;

-- Heartbeats and feed health validate against published content, not draft tables.
create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.screens screen_row
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where screen_row.id = input_screen_id
    and screen_row.is_active
    and (input_current_slide_id is null or exists (
      select 1 from public.player_playlist(input_screen_id) published(item)
      where published.item->>'id' = input_current_slide_id::text
    ));
end;
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

create or replace function public.player_report_feed_status(
  input_screen_id uuid,
  input_slide_id uuid,
  input_status text,
  input_http_status integer default null,
  input_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  screen_row public.screens%rowtype;
  feed_title text;
  feed_source_url text;
  host_value text;
begin
  if input_status not in ('ok', 'http_error', 'network_error', 'invalid_json') then
    raise exception 'Unsupported feed status';
  end if;
  select * into screen_row from public.screens
    where id = input_screen_id and is_active and activated_at is not null;
  if not found then return; end if;
  select item->>'title', item->>'source_url' into feed_title, feed_source_url
  from public.player_playlist(input_screen_id) as published(item)
  where item->>'id' = input_slide_id::text and item->>'kind' = 'feed'
  limit 1;
  if not found then return; end if;
  if exists (
    select 1 from public.screen_feed_status
    where screen_id = screen_row.id and slide_id = input_slide_id
      and last_attempt_at > now() - interval '5 seconds'
  ) then return; end if;
  host_value := regexp_replace(
    split_part(split_part(coalesce(feed_source_url, ''), '://', 2), '/', 1), '[?#].*$', ''
  );
  insert into public.screen_feed_status(
    screen_id, slide_id, screen_name, screen_group_id, feed_title, source_host,
    status, last_attempt_at, last_success_at, last_http_status, last_error_code
  ) values (
    screen_row.id, input_slide_id, screen_row.name, screen_row.group_id,
    coalesce(nullif(feed_title, ''), 'Live-feed'), host_value,
    input_status, now(), case when input_status = 'ok' then now() else null end,
    input_http_status, left(nullif(input_error_code, ''), 40)
  )
  on conflict (screen_id, slide_id) do update set
    screen_name = excluded.screen_name,
    screen_group_id = excluded.screen_group_id,
    feed_title = excluded.feed_title,
    source_host = excluded.source_host,
    status = excluded.status,
    last_attempt_at = excluded.last_attempt_at,
    last_success_at = case when excluded.status = 'ok'
      then excluded.last_success_at else public.screen_feed_status.last_success_at end,
    last_http_status = excluded.last_http_status,
    last_error_code = excluded.last_error_code;
end;
$$;
revoke all on function public.player_report_feed_status(uuid, uuid, text, integer, text) from public;
grant execute on function public.player_report_feed_status(uuid, uuid, text, integer, text) to anon, authenticated;

commit;
