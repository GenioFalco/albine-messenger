-- Albine Messenger — M5 stage 1: allow 'voice' messages.
--
-- Voice notes reuse the media pipeline (encrypted blob in the `media` bucket,
-- per-file key sealed to each member) and are just another content_type. The
-- original 0001 CHECK only allowed text/image/file/system, so inserting a
-- voice message failed with:
--   new row for relation "messages" violates check constraint
--   "messages_content_type_check"
-- Widen the constraint to include 'voice'. Safe to re-run.

alter table messages drop constraint if exists messages_content_type_check;
alter table messages
  add constraint messages_content_type_check
  check (content_type in ('text', 'image', 'file', 'system', 'voice'));
