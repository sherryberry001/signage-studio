-- Store TV screenshots privately so only authorized team members can view them.
begin;

alter table public.screens add column if not exists preview_updated_at timestamptz;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('signage-previews', 'signage-previews', false, 2097152, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 2097152,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Team can read live screen previews" on storage.objects;
create policy "Team can read live screen previews" on storage.objects
  for select to authenticated using (
    bucket_id = 'signage-previews'
    and case
      when name ~ '^screens/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/current\.jpg$'
      then public.team_has_role(array['admin','editor','viewer'])
        or public.user_can_access_screen(split_part(name, '/', 2)::uuid)
      else false
    end
  );

commit;
