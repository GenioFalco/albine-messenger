-- Per-user conversation preferences (pin/mute/hide) and per-message actions
-- (reply, pin, forward, edit).
--
-- No RLS changes needed: conversation_members already has "members can
-- update own membership row" (using user_id = auth.uid()), which covers
-- pinned_at/muted/hidden_at; messages already has "soft-delete/edit own
-- messages" for the sender, and reply_to_id/forwarded_from_sender_id are
-- just extra columns on a normal insert (already covered by the existing
-- insert policy). Pinning a message is the one exception — any member
-- should be able to pin/unpin, not just the original sender — handled via
-- a narrow SECURITY DEFINER RPC that only ever touches pinned_at, so a
-- member can never use it to smuggle a ciphertext/content change into
-- someone else's message.

alter table conversation_members add column if not exists pinned_at timestamptz;
alter table conversation_members add column if not exists muted boolean not null default false;
-- "Delete chat" is per-user and local-only in effect: hides the conversation
-- from *this* account's list without touching the other member(s)' rows or
-- any message. A later incoming message (created_at after hidden_at) makes
-- it reappear automatically, same as WhatsApp/Telegram.
alter table conversation_members add column if not exists hidden_at timestamptz;

alter table messages add column if not exists reply_to_id uuid references messages(id) on delete set null;
alter table messages add column if not exists pinned_at timestamptz;
-- Original sender of a forwarded message, kept only for the "Переслано от
-- X" label — forwarding re-encrypts the (locally-decrypted) plaintext fresh
-- for the target conversation, so the forwarded row is otherwise a normal
-- independent message, not a reference to the original ciphertext.
alter table messages add column if not exists forwarded_from_sender_id uuid references profiles(id);
-- Marks this row as an edit event rather than a normal visible message: the
-- ciphertext here decrypts to the *new* text for the message `edits_message_id`
-- points at. Editing a signal-protocol message can't safely overwrite the
-- original row's ciphertext in place (that message's one-time key is
-- already discarded — forward secrecy working as intended, same reason
-- outgoing signal messages need the local sent-echo cache), so instead an
-- edit is its own new encrypted message, applied client-side as an override
-- for the target's displayed text rather than rendered as a separate bubble.
alter table messages add column if not exists edits_message_id uuid references messages(id) on delete set null;

create or replace function toggle_message_pin(p_message_id uuid, p_pin boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conversation_id uuid;
begin
  select conversation_id into v_conversation_id from messages where id = p_message_id;
  if v_conversation_id is null or not is_conversation_member(v_conversation_id, auth.uid()) then
    raise exception 'not a member of this conversation';
  end if;
  update messages set pinned_at = case when p_pin then now() else null end where id = p_message_id;
end;
$$;
