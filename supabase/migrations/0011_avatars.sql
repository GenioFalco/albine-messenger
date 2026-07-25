-- Avatars (profile + group) — unlike the `media` bucket, avatars are public:
-- a display picture isn't secret content (every other messenger shows them
-- to anyone who can see the account/group at all), and making them public
-- lets the client just store a plain URL and render it directly, no signed
-- URLs or client-side decryption to manage.
--
-- Object path convention: `profile/<user_id>/<uuid>` or
-- `group/<conversation_id>/<uuid>` — a fresh path on every re-upload rather
-- than overwriting in place, so there's no upsert-conflict handling to get
-- right; the *_url column is simply repointed at the new object. This does
-- leave the previous avatar's object orphaned in storage on re-upload — an
-- accepted trade-off for a friends-scale app, not worth a cleanup job yet.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- Public bucket → reads need no policy (Storage serves public-bucket objects
-- directly, bypassing RLS). Writes still need one each.
drop policy if exists "avatars: users can upload their own profile picture" on storage.objects;
create policy "avatars: users can upload their own profile picture"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and split_part(name, '/', 1) = 'profile'
    and split_part(name, '/', 2) = auth.uid()::text
  );

drop policy if exists "avatars: group owner/admin can upload group picture" on storage.objects;
create policy "avatars: group owner/admin can upload group picture"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and split_part(name, '/', 1) = 'group'
    and is_conversation_admin((split_part(name, '/', 2))::uuid, auth.uid())
  );

-- `conversations.avatar_url` — reuses the UPDATE policy already added in
-- 0010_group_management.sql ("owner/admin can rename conversation" is
-- actually a general owner/admin UPDATE policy on the whole row, not
-- title-specific, so it already covers this new column too).
alter table conversations add column if not exists avatar_url text;
