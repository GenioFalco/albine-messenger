-- Albine Messenger — M1.5 hotfix: cross-device decrypt failures + read receipts
--
-- Two independent fixes bundled into one file (both small, both discovered in
-- the same live-testing session):
--
-- 1. One-time prekey "orphan" cleanup. When a device loses its *local* Signal
--    store (cleared browser data, a different origin — e.g. localhost vs
--    127.0.0.1 — or the "rotate key" action) its published one-time prekeys on
--    the server survive, but their private halves are gone. Every session a
--    peer builds from such a prekey then fails forever with
--    "InvalidKeyIdException - No such prekey: N", and the client's top-up logic
--    refuses to replace them because the server count still looks healthy. The
--    fix (client side) deletes and republishes the whole bundle on a fresh
--    bootstrap / on first decrypt failure — which needs a DELETE policy the
--    original 0003 migration never granted.
--
-- 2. Read receipts weren't flipping to the double-check. Rather than depend on
--    the exact interaction of two permissive UPDATE policies on `messages`,
--    mark-as-read now goes through a SECURITY DEFINER RPC that checks
--    membership explicitly and updates in one shot — same pattern as
--    create_direct_conversation / claim_one_time_prekey. The WAL change it
--    produces still reaches Supabase Realtime, so the sender's tick updates
--    live.
--
-- Safe to re-run (drop-then-create / if-not-exists throughout), matching the
-- convention in 0001_init.sql.

-- ---- 1. prekey owner-delete policies -------------------------------------

drop policy if exists "one-time prekeys owner delete" on one_time_prekeys;
create policy "one-time prekeys owner delete"
  on one_time_prekeys for delete
  using (auth.uid() = user_id);

drop policy if exists "signed prekeys owner delete" on signed_prekeys;
create policy "signed prekeys owner delete"
  on signed_prekeys for delete
  using (auth.uid() = user_id);

-- ---- 2. mark-conversation-read RPC ---------------------------------------

create or replace function mark_conversation_read(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only a member may mark a conversation read (and never their own messages).
  if not is_conversation_member(p_conversation_id, auth.uid()) then
    return;
  end if;

  update messages
     set read_at = now()
   where conversation_id = p_conversation_id
     and sender_id <> auth.uid()
     and read_at is null;
end;
$$;
