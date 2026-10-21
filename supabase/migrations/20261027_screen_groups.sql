-- Organize screens by office, floor, department, or any other location label.
create table if not exists public.screen_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 64),
  description text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.screens add column if not exists group_id uuid;
alter table public.screens drop constraint if exists screens_group_id_fkey;
alter table public.screens add constraint screens_group_id_fkey
  foreign key (group_id) references public.screen_groups(id) on delete set null;
create index if not exists screens_group_idx on public.screens(group_id, created_at desc);
create unique index if not exists screen_groups_name_ci_idx on public.screen_groups(lower(btrim(name)));

alter table public.screen_groups enable row level security;
grant select, insert, update, delete on public.screen_groups to authenticated;
drop policy if exists "Team members read screen groups" on public.screen_groups;
create policy "Team members read screen groups" on public.screen_groups
  for select to authenticated
  using (public.team_has_role(array['admin','editor','viewer']));
drop policy if exists "Admins manage screen groups" on public.screen_groups;
create policy "Admins manage screen groups" on public.screen_groups
  for all to authenticated
  using (public.team_has_role(array['admin']))
  with check (public.team_has_role(array['admin']));
