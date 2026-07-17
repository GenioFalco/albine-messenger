-- Messages are now hard-deleted client-side (chat_repository.dart's
-- deleteMessage) instead of soft-deleted with deleted_at + scrubbed
-- ciphertext — a deleted message has no reason to linger in the database.
-- The table only had an UPDATE policy before (for the old soft-delete/edit
-- approach), so an explicit DELETE policy is needed.
create policy "delete own messages"
  on messages for delete
  using (sender_id = auth.uid());

-- One-off cleanup: remove rows already soft-deleted under the old scheme
-- (deleted_at set, ciphertext already blanked) so they stop lingering as
-- dead rows — e.g. a deleted message that happened to be a conversation's
-- most recent one no longer needs special-casing in the "last message"
-- preview logic once it's just gone.
delete from messages where deleted_at is not null;
