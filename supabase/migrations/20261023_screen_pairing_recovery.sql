-- Re-pair a reset player with its existing screen profile instead of creating
-- a second screen record with a new one-time activation code.
begin;

create or replace function public.renew_screen_pairing_code(input_screen_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
begin
  if public.current_team_role() is distinct from 'admin' then
    raise exception 'Only admins can renew a screen pairing code' using errcode = '42501';
  end if;
  if not exists (select 1 from public.screens where id = input_screen_id and is_active) then
    raise exception 'Screen was not found or is paused';
  end if;

  for attempt_no in 1..20 loop
    candidate := '';
    for char_idx in 1..6 loop
      candidate := candidate || substr(alphabet, (get_byte(gen_random_bytes(1), 0) % length(alphabet)) + 1, 1);
    end loop;
    if exists (select 1 from public.screens where pair_code = candidate) then
      continue;
    end if;
    begin
      update public.screens set pair_code = candidate where id = input_screen_id and is_active;
      if found then return candidate; end if;
    exception when unique_violation then
      -- Another admin generated this code at the same time; choose a new one.
      null;
    end;
  end loop;
  raise exception 'Could not generate a unique pairing code. Try again.';
end;
$$;
revoke all on function public.renew_screen_pairing_code(uuid) from public;
grant execute on function public.renew_screen_pairing_code(uuid) to authenticated;

commit;
