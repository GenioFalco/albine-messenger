-- Read receipts: single check (sent) / double check (read), same signal as
-- WhatsApp/Telegram. No separate "delivered" state — Supabase Realtime
-- delivery is near-instant and not worth its own timestamp/column; a message
-- is either not yet read or read, mirroring what the UI actually shows.
--
-- Design note for groups: this is a single `read_at` per message, set the
-- first time *any* other member reads it — not a per-member matrix (that
-- would need a join table and isn't worth it for a friends-scale app with no
-- group read-receipt UI planned). For a direct (1:1) conversation this is
-- exactly the correct semantics already, since there's only one other
-- member. Documented as a deliberate v1 scope limit, same style as other
-- accepted trade-offs in ROADMAP.md.
alter table messages add column read_at timestamptz;

-- Recipients (not the sender) need to be able to set read_at on someone
-- else's message when they open the chat — the existing "soft-delete/edit
-- own messages" policy only covers the sender's own rows. Postgres OR's
-- multiple permissive policies for the same command together, so this adds
-- to that rather than replacing it. Not column-restricted (RLS is row-level
-- only) — same trust boundary as the rest of this app: the client is trusted
-- to only ever send a read_at update through this path.
create policy "mark others' messages read"
  on messages for update
  using (sender_id <> auth.uid() and is_conversation_member(conversation_id, auth.uid()))
  with check (sender_id <> auth.uid() and is_conversation_member(conversation_id, auth.uid()));
