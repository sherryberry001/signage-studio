-- Prevent concurrent admin sessions from creating multiple active profiles
-- with the same screen name. Re-pairing continues to reuse the existing row.
begin;

create unique index if not exists screens_name_ci_active_idx
  on public.screens(lower(btrim(name)))
  where is_active = true;

commit;
