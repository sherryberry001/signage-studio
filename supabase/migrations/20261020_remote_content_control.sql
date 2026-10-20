-- Let admins and editors select the active content shown now without granting
-- general UPDATE access to screen/device records.
begin;

create or replace function public.set_screen_forced_slide(input_screen_id uuid, input_slide_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_playlist_id uuid;
begin
  if public.current_team_role() is distinct from 'admin'
     and public.current_team_role() is distinct from 'editor' then
    raise exception 'Only admins and editors can control screen content' using errcode = '42501';
  end if;

  select playlist_id into target_playlist_id
    from public.screens where id = input_screen_id and is_active = true for update;
  if not found then
    raise exception 'Screen was not found or is paused';
  end if;

  if input_slide_id is not null and not exists (
    select 1 from public.slides sl
    where sl.id = input_slide_id and sl.is_active = true
      and (sl.playlist_id = target_playlist_id or (target_playlist_id is null and sl.screen_id = input_screen_id))
  ) then
    raise exception 'The selected item is not active on this screen';
  end if;

  update public.screens set forced_slide_id = input_slide_id where id = input_screen_id;
end;
$$;
revoke all on function public.set_screen_forced_slide(uuid, uuid) from public;
grant execute on function public.set_screen_forced_slide(uuid, uuid) to authenticated;

commit;
