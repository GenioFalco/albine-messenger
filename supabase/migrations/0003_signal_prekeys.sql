-- Albine Messenger — M1.5 phase 2: forward secrecy for 1:1 chats
--
-- Adds the X3DH prekey directory needed to bootstrap a libsignal_protocol_dart
-- Double Ratchet session between two users, plus the message-envelope columns
-- to record which protocol a given row used. Old rows keep protocol =
-- 'crypto_box' and stay readable forever via the untouched legacy path.

-- One stable Signal "registration id" per account, alongside the existing
-- X25519 identity_pubkey it re-uses as the Signal identity key.
alter table profiles add column if not exists signal_registration_id int;

-- Current signed prekey per user. v1 keeps exactly one (replaced wholesale on
-- rotation) — no multi-signed-prekey grace window, matching ROADMAP.md's
-- accepted v1 scope.
drop table if exists signed_prekeys cascade;
create table signed_prekeys (
  user_id uuid primary key references profiles(id) on delete cascade,
  key_id int not null,
  public_key text not null,   -- base64, libsignal's serialize() (type-byte + 32 bytes)
  signature text not null,    -- base64, XEdDSA signature by the identity key
  created_at timestamptz not null default now()
);
alter table signed_prekeys enable row level security;
create policy "signed prekeys readable by authenticated"
  on signed_prekeys for select
  using (auth.uid() is not null);
create policy "signed prekeys owner insert"
  on signed_prekeys for insert
  with check (auth.uid() = user_id);
create policy "signed prekeys owner update"
  on signed_prekeys for update
  using (auth.uid() = user_id);

-- Pool of one-time prekeys per user, topped up by the client. Each is handed
-- out exactly once via claim_one_time_prekey() below, then deleted.
drop table if exists one_time_prekeys cascade;
create table one_time_prekeys (
  user_id uuid not null references profiles(id) on delete cascade,
  key_id int not null,
  public_key text not null,
  primary key (user_id, key_id)
);
alter table one_time_prekeys enable row level security;
create policy "one-time prekeys owner select"
  on one_time_prekeys for select
  using (auth.uid() = user_id);
create policy "one-time prekeys owner insert"
  on one_time_prekeys for insert
  with check (auth.uid() = user_id);

-- Atomically hands out and deletes one one-time prekey so two concurrent
-- senders can never claim the same one. SECURITY DEFINER bypasses the
-- owner-only select policy above inside the function body only, same
-- pattern as is_conversation_member() in 0001_init.sql.
create or replace function claim_one_time_prekey(target_user_id uuid)
returns table(key_id int, public_key text)
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
begin
  select o.key_id, o.public_key into rec
  from one_time_prekeys o
  where o.user_id = target_user_id
  order by o.key_id
  limit 1
  for update skip locked;

  if rec is null then
    return;
  end if;

  delete from one_time_prekeys where user_id = target_user_id and key_id = rec.key_id;
  return query select rec.key_id, rec.public_key;
end;
$$;

-- Message envelope: which protocol encrypted this row, and (for 'signal'
-- rows) the libsignal CiphertextMessage type (2 = whisper/ratchet,
-- 3 = prekey/session-establishing) so the receiver knows how to parse it.
-- A serialized libsignal ciphertext carries its own ratchet metadata, so
-- `nonce` (meaningful only for the legacy crypto_box path) is no longer
-- always present.
alter table messages add column if not exists protocol text not null default 'crypto_box'
  check (protocol in ('crypto_box', 'signal'));
alter table messages add column if not exists signal_message_type int;
alter table messages alter column nonce drop not null;
