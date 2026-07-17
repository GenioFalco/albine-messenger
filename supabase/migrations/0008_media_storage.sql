-- M3: encrypted media (photo/video/file) attachments.
--
-- Storage holds ciphertext only, same trust boundary as everything else —
-- the per-file symmetric key is sealed (crypto_box_seal) to every
-- conversation member (including the sender, same reason group text keys
-- are sealed to self too: so the sender can still open their own sent
-- media after a reload). `messages.media_object_path`/`media_wrapped_key`/
-- `media_nonce`/`media_size_bytes`/`media_mime_hint` already exist
-- (0001_init.sql) — this migration only adds the bucket + its policies.
--
-- Object path convention: `<conversation_id>/<random_id>` — lets the RLS
-- policies below authorize purely from the path, reusing the existing
-- is_conversation_member() helper, without a second lookup table.
insert into storage.buckets (id, name, public)
values ('media', 'media', false)
on conflict (id) do nothing;

create policy "media: members can read"
  on storage.objects for select
  using (bucket_id = 'media' and is_conversation_member((split_part(name, '/', 1))::uuid, auth.uid()));

create policy "media: members can upload"
  on storage.objects for insert
  with check (bucket_id = 'media' and is_conversation_member((split_part(name, '/', 1))::uuid, auth.uid()));
