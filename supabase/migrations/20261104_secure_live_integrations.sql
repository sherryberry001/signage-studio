-- Keep external feed credentials out of content rows and expose them only to
-- the assigned player after it proves its screen and slide IDs.
begin;

create table if not exists public.signage_integrations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 100),
  provider text not null check (provider in ('dizparc_pulse')),
  endpoint_url text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (endpoint_url ~ '^https?://[^/?#]+(/[^?#]*)?$'),
  check (split_part(split_part(endpoint_url, '://', 2), '/', 1) !~ '@')
);
create table if not exists public.signage_integration_secrets (
  integration_id uuid primary key references public.signage_integrations(id) on delete cascade,
  display_token text not null check (char_length(display_token) >= 32),
  updated_at timestamptz not null default now()
);

alter table public.signage_integrations enable row level security;
alter table public.signage_integration_secrets enable row level security;
revoke all on public.signage_integrations from public, anon, authenticated;
revoke all on public.signage_integration_secrets from public, anon, authenticated;

alter table public.media_library
  add column if not exists integration_id uuid references public.signage_integrations(id) on delete set null;
alter table public.slides
  add column if not exists integration_id uuid references public.signage_integrations(id) on delete set null;
create index if not exists media_library_integration_idx on public.media_library(integration_id)
  where integration_id is not null;
create index if not exists slides_integration_idx on public.slides(integration_id)
  where integration_id is not null;

-- Move existing Pulse tokens out of feed URLs into the private credential table.
do $$
declare
  feed_row record;
  endpoint_value text;
  token_value text;
  integration_value uuid;
begin
  for feed_row in
    select title, source_url from public.slides where kind = 'feed' and source_url like '%#token=%'
    union
    select title, source_url from public.media_library where kind = 'feed' and source_url like '%#token=%'
  loop
    endpoint_value := split_part(feed_row.source_url, '#token=', 1);
    token_value := substring(feed_row.source_url from '#token=(.*)$');
    if endpoint_value !~ '^https?://[^/?#]+(/[^?#]*)?$' or char_length(token_value) < 32 then
      continue;
    end if;
    select integration.id into integration_value
      from public.signage_integrations integration
      join public.signage_integration_secrets secret on secret.integration_id = integration.id
      where integration.endpoint_url = endpoint_value and secret.display_token = token_value
      limit 1;
    if integration_value is null then
      insert into public.signage_integrations(name, provider, endpoint_url)
        values (left(coalesce(nullif(btrim(feed_row.title), ''), 'Dizparc Pulse'), 100), 'dizparc_pulse', endpoint_value)
        returning id into integration_value;
      insert into public.signage_integration_secrets(integration_id, display_token)
        values (integration_value, token_value);
    end if;
  end loop;

  update public.media_library media
    set integration_id = integration.id, source_url = integration.endpoint_url, updated_at = now()
    from public.signage_integrations integration
    join public.signage_integration_secrets secret on secret.integration_id = integration.id
    where media.kind = 'feed' and media.source_url like '%#token=%'
      and integration.endpoint_url = split_part(media.source_url, '#token=', 1)
      and secret.display_token = substring(media.source_url from '#token=(.*)$');

  update public.slides slide
    set integration_id = integration.id, source_url = integration.endpoint_url
    from public.signage_integrations integration
    join public.signage_integration_secrets secret on secret.integration_id = integration.id
    where slide.kind = 'feed' and slide.source_url like '%#token=%'
      and integration.endpoint_url = split_part(slide.source_url, '#token=', 1)
      and secret.display_token = substring(slide.source_url from '#token=(.*)$');
end;
$$;

create or replace function public.sync_media_library_references()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.slides
  set kind = new.kind, title = new.title, body = new.body,
      source_url = new.source_url, integration_id = new.integration_id,
      refresh_interval_seconds = new.refresh_interval_seconds
  where library_asset_id = new.id;
  return new;
end;
$$;
drop trigger if exists sync_media_library_references on public.media_library;
create trigger sync_media_library_references
  after update of kind, title, body, source_url, integration_id, refresh_interval_seconds on public.media_library
  for each row execute function public.sync_media_library_references();

drop trigger if exists activity_slides_update on public.slides;
create trigger activity_slides_update after update of screen_id, playlist_id, integration_id, kind, title, body, source_url,
  library_asset_id, duration_seconds, refresh_interval_seconds, sort_order, is_active,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.slides for each row execute function public.capture_activity_log();
drop trigger if exists activity_media_library_update on public.media_library;
create trigger activity_media_library_update after update of kind, title, body, source_url,
  integration_id, duration_seconds, refresh_interval_seconds, tags on public.media_library
  for each row execute function public.capture_activity_log();

create or replace function public.team_list_signage_integrations()
returns table(id uuid, name text, provider text, endpoint_url text, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if coalesce(public.current_team_role(), '') not in ('admin', 'editor') then
    raise exception 'Only admins and editors can manage integrations' using errcode = '42501';
  end if;
  return query
    select integration.id, integration.name, integration.provider,
           integration.endpoint_url, integration.updated_at
    from public.signage_integrations integration
    order by integration.name;
end;
$$;
revoke all on function public.team_list_signage_integrations() from public, anon;
grant execute on function public.team_list_signage_integrations() to authenticated;

create or replace function public.manage_signage_integration(
  input_integration_id uuid,
  input_name text,
  input_endpoint_url text,
  input_display_token text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  result_id uuid;
  clean_endpoint text := btrim(input_endpoint_url);
  clean_name text := btrim(input_name);
  clean_token text := nullif(btrim(input_display_token), '');
begin
  if public.current_team_role() is distinct from 'admin' then
    raise exception 'Only admins can manage integration credentials' using errcode = '42501';
  end if;
  if char_length(clean_name) not between 1 and 100 then
    raise exception 'Integration name must be 1 to 100 characters';
  end if;
  if clean_endpoint !~ '^https?://[^/?#]+(/[^?#]*)?$'
     or split_part(split_part(clean_endpoint, '://', 2), '/', 1) ~ '@' then
    raise exception 'Use an HTTP(S) endpoint without URL credentials, query parameters, or fragments';
  end if;
  if clean_token is not null and char_length(clean_token) < 32 then
    raise exception 'Pulse display token must be at least 32 characters';
  end if;

  if input_integration_id is null then
    if clean_token is null then raise exception 'Pulse display token is required'; end if;
    insert into public.signage_integrations(name, provider, endpoint_url)
    values (clean_name, 'dizparc_pulse', clean_endpoint)
    returning id into result_id;
  else
    update public.signage_integrations
      set name = clean_name, endpoint_url = clean_endpoint, updated_at = now()
      where id = input_integration_id
      returning id into result_id;
    if result_id is null then raise exception 'Integration was not found'; end if;
    if clean_token is null and not exists (
      select 1 from public.signage_integration_secrets where integration_id = result_id
    ) then raise exception 'Pulse display token is required'; end if;
  end if;

  if clean_token is not null then
    insert into public.signage_integration_secrets(integration_id, display_token, updated_at)
    values (result_id, clean_token, now())
    on conflict (integration_id) do update
      set display_token = excluded.display_token, updated_at = excluded.updated_at;
  end if;
  update public.media_library set source_url = clean_endpoint, updated_at = now()
    where integration_id = result_id and source_url is distinct from clean_endpoint;
  update public.slides set source_url = clean_endpoint
    where integration_id = result_id and source_url is distinct from clean_endpoint;
  return result_id;
end;
$$;
revoke all on function public.manage_signage_integration(uuid, text, text, text) from public, anon;
grant execute on function public.manage_signage_integration(uuid, text, text, text) to authenticated;

create or replace function public.player_get_integration_config(input_screen_id uuid, input_slide_id uuid)
returns table(provider text, endpoint_url text, display_token text)
language plpgsql
security definer
set search_path = public
as $$
declare
  screen_row public.screens%rowtype;
  slide_integration_id uuid;
begin
  select * into screen_row from public.screens
    where id = input_screen_id and is_active and activated_at is not null;
  if not found then return; end if;

  select slide.integration_id into slide_integration_id
  from public.slides slide
  where slide.id = input_slide_id and slide.kind = 'feed' and slide.integration_id is not null
    and (
      slide.playlist_id = screen_row.playlist_id
      or slide.playlist_id = screen_row.zone_playlist_id
      or (slide.playlist_id is null and slide.screen_id = screen_row.id)
      or exists (
        select 1 from public.screen_channel_schedules schedule
        join public.channels channel on channel.id = schedule.channel_id
        join public.channel_playlists membership on membership.channel_id = channel.id
        where schedule.screen_id = screen_row.id and membership.playlist_id = slide.playlist_id
      )
    );
  if slide_integration_id is null then return; end if;

  return query
    select integration.provider, integration.endpoint_url, secret.display_token
    from public.signage_integrations integration
    join public.signage_integration_secrets secret on secret.integration_id = integration.id
    where integration.id = slide_integration_id;
end;
$$;
revoke all on function public.player_get_integration_config(uuid, uuid) from public;
grant execute on function public.player_get_integration_config(uuid, uuid) to anon, authenticated;

commit;
