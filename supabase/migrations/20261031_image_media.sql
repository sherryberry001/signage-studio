-- Add first-class image slides and allow standard still-image uploads.
begin;

alter table public.media_library drop constraint if exists media_library_kind_check;
alter table public.media_library add constraint media_library_kind_check
  check (kind in ('text', 'image', 'video', 'feed', 'web', 'clock'));

alter table public.slides drop constraint if exists slides_kind_check;
alter table public.slides add constraint slides_kind_check
  check (kind in ('text', 'image', 'video', 'clock', 'feed', 'web'));

update storage.buckets
set allowed_mime_types = array[
  'image/jpeg', 'image/png', 'image/webp',
  'video/mp4', 'video/webm', 'video/quicktime',
  'application/vnd.apple.mpegurl', 'application/x-mpegURL'
]
where id = 'signage-assets';

commit;
