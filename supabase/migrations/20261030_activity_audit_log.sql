-- Server-side audit history for important user-facing control-plane changes.
begin;

create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users(id) on delete set null,
  actor_email text not null,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  entity_type text not null,
  entity_id text not null,
  entity_label text not null,
  changed_fields text[] not null default '{}',
  created_at timestamptz not null default now()
);
create index if not exists activity_log_created_idx on public.activity_log(created_at desc, id desc);
create index if not exists activity_log_entity_idx on public.activity_log(entity_type, created_at desc);

alter table public.activity_log enable row level security;
revoke all on public.activity_log from anon, authenticated;
grant select on public.activity_log to authenticated;
drop policy if exists "Admins read activity log" on public.activity_log;
create policy "Admins read activity log" on public.activity_log
  for select to authenticated using (public.team_has_role(array['admin']));

create or replace function public.capture_activity_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  old_row jsonb := '{}'::jsonb;
  new_row jsonb := '{}'::jsonb;
  row_data jsonb;
  actor uuid := auth.uid();
  actor_name text;
  row_id text;
  row_label text;
  fields text[] := '{}';
begin
  if tg_op <> 'INSERT' then old_row := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then new_row := to_jsonb(new); end if;
  row_data := case when tg_op = 'DELETE' then old_row else new_row end;
  row_id := coalesce(row_data ->> 'id', row_data ->> 'user_id', 'unknown');
  row_label := coalesce(
    nullif(new_row ->> 'name', ''), nullif(old_row ->> 'name', ''),
    nullif(new_row ->> 'title', ''), nullif(old_row ->> 'title', ''),
    nullif(new_row ->> 'email', ''), nullif(old_row ->> 'email', ''),
    nullif(new_row ->> 'command', ''), left(row_id, 8)
  );

  if tg_op = 'UPDATE' then
    select coalesce(array_agg(n.key order by n.key), '{}') into fields
      from jsonb_each(new_row) as n(key, value)
      where old_row -> n.key is distinct from n.value
        and n.key <> 'updated_at';
    if cardinality(fields) = 0 then return new; end if;
  end if;

  if actor is not null then
    select tm.email into actor_name from public.team_members tm where tm.user_id = actor;
  end if;

  insert into public.activity_log(actor_id, actor_email, action, entity_type, entity_id, entity_label, changed_fields)
  values (actor, coalesce(actor_name, 'System/automatiserat'), tg_op, tg_table_name, row_id, row_label, fields);

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function public.capture_activity_log() from public, anon, authenticated;

-- Track only administrative columns on screens; TV heartbeats update current_* and last_seen_at.
drop trigger if exists activity_screens_insert_delete on public.screens;
create trigger activity_screens_insert_delete after insert or delete on public.screens
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_screens_update on public.screens;
create trigger activity_screens_update after update of name, is_active, group_id, playlist_id,
  forced_slide_id, forced_until, zone_playlist_id, layout_type, layout_text,
  operating_weekdays, operating_start_time, operating_end_time, playback_mode, autostart_enabled
  on public.screens for each row execute function public.capture_activity_log();

drop trigger if exists activity_slides_insert_delete on public.slides;
create trigger activity_slides_insert_delete after insert or delete on public.slides
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_slides_update on public.slides;
create trigger activity_slides_update after update of screen_id, playlist_id, kind, title, body, source_url,
  library_asset_id, duration_seconds, refresh_interval_seconds, sort_order, is_active,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.slides for each row execute function public.capture_activity_log();

drop trigger if exists activity_playlists_insert_delete on public.playlists;
create trigger activity_playlists_insert_delete after insert or delete on public.playlists
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_playlists_update on public.playlists;
create trigger activity_playlists_update after update of name on public.playlists
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_media_library_insert_delete on public.media_library;
create trigger activity_media_library_insert_delete after insert or delete on public.media_library
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_media_library_update on public.media_library;
create trigger activity_media_library_update after update of kind, title, body, source_url,
  duration_seconds, refresh_interval_seconds, tags on public.media_library
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_channels_insert_delete on public.channels;
create trigger activity_channels_insert_delete after insert or delete on public.channels
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_channels_update on public.channels;
create trigger activity_channels_update after update of name, playlist_id on public.channels
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_channel_playlists_insert_delete on public.channel_playlists;
create trigger activity_channel_playlists_insert_delete after insert or delete on public.channel_playlists
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_channel_playlists_update on public.channel_playlists;
create trigger activity_channel_playlists_update after update of channel_id, playlist_id, sort_order, priority,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.channel_playlists for each row execute function public.capture_activity_log();

drop trigger if exists activity_screen_schedules_insert_delete on public.screen_channel_schedules;
create trigger activity_screen_schedules_insert_delete after insert or delete on public.screen_channel_schedules
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_screen_schedules_update on public.screen_channel_schedules;
create trigger activity_screen_schedules_update after update of screen_id, channel_id, priority,
  active_from, active_until, weekdays, daily_start_time, daily_end_time
  on public.screen_channel_schedules for each row execute function public.capture_activity_log();

drop trigger if exists activity_screen_groups_insert_delete on public.screen_groups;
create trigger activity_screen_groups_insert_delete after insert or delete on public.screen_groups
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_screen_groups_update on public.screen_groups;
create trigger activity_screen_groups_update after update of name, description on public.screen_groups
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_group_members_insert_delete on public.screen_group_members;
create trigger activity_group_members_insert_delete after insert or delete on public.screen_group_members
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_team_members_insert_delete on public.team_members;
create trigger activity_team_members_insert_delete after insert or delete on public.team_members
  for each row execute function public.capture_activity_log();
drop trigger if exists activity_team_members_update on public.team_members;
create trigger activity_team_members_update after update of email, role on public.team_members
  for each row execute function public.capture_activity_log();

drop trigger if exists activity_screen_commands_insert on public.screen_commands;
create trigger activity_screen_commands_insert after insert on public.screen_commands
  for each row execute function public.capture_activity_log();

commit;
