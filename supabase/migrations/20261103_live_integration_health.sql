-- Per-player health for JSON/Pulse feeds. Keep source credentials private from
-- the status view; only the host and sanitized result are retained here.
begin;

create table if not exists public.screen_feed_status (
  screen_id uuid not null references public.screens(id) on delete cascade,
  slide_id uuid not null references public.slides(id) on delete cascade,
  screen_name text not null,
  screen_group_id uuid references public.screen_groups(id) on delete set null,
  feed_title text not null,
  source_host text not null default '',
  status text not null check (status in ('ok', 'http_error', 'network_error', 'invalid_json')),
  last_attempt_at timestamptz not null default now(),
  last_success_at timestamptz,
  last_http_status integer,
  last_error_code text,
  primary key (screen_id, slide_id)
);

create index if not exists screen_feed_status_attempt_idx
  on public.screen_feed_status(last_attempt_at desc);
create index if not exists screen_feed_status_group_idx
  on public.screen_feed_status(screen_group_id, last_attempt_at desc);

alter table public.screen_feed_status enable row level security;
revoke all on public.screen_feed_status from anon, authenticated;
grant select on public.screen_feed_status to authenticated;
drop policy if exists "Team can read live feed health" on public.screen_feed_status;
create policy "Team can read live feed health" on public.screen_feed_status
  for select to authenticated
  using (
    public.team_has_role(array['admin', 'editor', 'viewer'])
    or public.user_can_access_screen(screen_id)
    or (screen_group_id is not null and public.user_can_access_group(screen_group_id))
  );

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
  slide_row public.slides%rowtype;
  host_value text;
begin
  if input_status not in ('ok', 'http_error', 'network_error', 'invalid_json') then
    raise exception 'Unsupported feed status';
  end if;

  select * into screen_row
  from public.screens
  where id = input_screen_id and is_active and activated_at is not null;
  if not found then return; end if;

  select * into slide_row
  from public.slides sl
  where sl.id = input_slide_id and sl.kind = 'feed'
    and (
      sl.playlist_id = screen_row.playlist_id
      or sl.playlist_id = screen_row.zone_playlist_id
      or (sl.playlist_id is null and sl.screen_id = screen_row.id)
      or exists (
        select 1
        from public.screen_channel_schedules scs
        join public.channels ch on ch.id = scs.channel_id
        join public.channel_playlists cp on cp.channel_id = ch.id
        where scs.screen_id = screen_row.id and cp.playlist_id = sl.playlist_id
      )
    );
  if not found then return; end if;

  if exists (
    select 1 from public.screen_feed_status
    where screen_id = screen_row.id and slide_id = slide_row.id
      and last_attempt_at > now() - interval '5 seconds'
  ) then
    return;
  end if;

  host_value := regexp_replace(
    split_part(split_part(coalesce(slide_row.source_url, ''), '://', 2), '/', 1),
    '[?#].*$', ''
  );

  insert into public.screen_feed_status(
    screen_id, slide_id, screen_name, screen_group_id, feed_title, source_host,
    status, last_attempt_at, last_success_at, last_http_status, last_error_code
  ) values (
    screen_row.id, slide_row.id, screen_row.name, screen_row.group_id,
    coalesce(nullif(slide_row.title, ''), 'Live-feed'), host_value,
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
