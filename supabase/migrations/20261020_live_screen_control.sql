-- Adds live player status, direct item selection, and web/dashboard slides.
-- Safe to run on an existing Signage Studio installation.
begin;

alter table public.screens add column if not exists last_seen_at timestamptz;
alter table public.screens add column if not exists current_slide_id uuid;
alter table public.screens add column if not exists current_title text not null default 'Väntar på innehåll';
alter table public.screens add column if not exists current_body text not null default '';
alter table public.screens add column if not exists current_kind text;
alter table public.screens add column if not exists current_source_url text;
alter table public.screens add column if not exists forced_slide_id uuid;

alter table public.slides drop constraint if exists slides_kind_check;
alter table public.slides add constraint slides_kind_check
  check (kind in ('text', 'video', 'clock', 'feed', 'web'));

alter table public.screens drop constraint if exists screens_forced_slide_id_fkey;
alter table public.screens add constraint screens_forced_slide_id_fkey
  foreign key (forced_slide_id) references public.slides(id) on delete set null;
alter table public.screens drop constraint if exists screens_current_slide_id_fkey;
alter table public.screens add constraint screens_current_slide_id_fkey
  foreign key (current_slide_id) references public.slides(id) on delete set null;

create or replace function public.player_playlist(input_screen_id uuid)
returns setof public.slides
language sql
stable
security definer
set search_path = public
as $$
  select sl.*
  from public.slides sl
  join public.screens sc on sc.id = sl.screen_id
  where sc.id = input_screen_id and sc.is_active = true and sl.is_active = true
    and (sc.forced_slide_id is null or sl.id = sc.forced_slide_id)
  order by sl.sort_order asc, sl.created_at asc;
$$;
revoke all on function public.player_playlist(uuid) from public;
grant execute on function public.player_playlist(uuid) to anon, authenticated;

create or replace function public.player_heartbeat(
  input_screen_id uuid,
  input_current_slide_id uuid,
  input_current_title text,
  input_current_body text,
  input_current_kind text,
  input_current_source_url text
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.screens
  set last_seen_at = now(),
      current_slide_id = input_current_slide_id,
      current_title = coalesce(nullif(input_current_title, ''), 'Väntar på innehåll'),
      current_body = coalesce(input_current_body, ''),
      current_kind = input_current_kind,
      current_source_url = input_current_source_url
  where id = input_screen_id
    and (input_current_slide_id is null or exists (
      select 1 from public.slides sl
      where sl.id = input_current_slide_id and sl.screen_id = input_screen_id
    ));
$$;
revoke all on function public.player_heartbeat(uuid, uuid, text, text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, uuid, text, text, text, text) to anon, authenticated;

commit;
