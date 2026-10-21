-- Refresh JSON dashboards while they are on screen, independently of playlist dwell time.
begin;

alter table public.media_library
  add column if not exists refresh_interval_seconds integer not null default 30;
alter table public.media_library drop constraint if exists media_library_refresh_interval_check;
alter table public.media_library add constraint media_library_refresh_interval_check
  check (refresh_interval_seconds between 10 and 3600);

alter table public.slides
  add column if not exists refresh_interval_seconds integer not null default 30;
alter table public.slides drop constraint if exists slides_refresh_interval_check;
alter table public.slides add constraint slides_refresh_interval_check
  check (refresh_interval_seconds between 10 and 3600);

create or replace function public.sync_media_library_references()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.slides
  set kind = new.kind,
      title = new.title,
      body = new.body,
      source_url = new.source_url,
      refresh_interval_seconds = new.refresh_interval_seconds
  where library_asset_id = new.id;
  return new;
end;
$$;

drop trigger if exists sync_media_library_references on public.media_library;
create trigger sync_media_library_references
  after update of kind, title, body, source_url, refresh_interval_seconds on public.media_library
  for each row execute function public.sync_media_library_references();

commit;
