-- Albine Messenger — M1.5 phase 1: encrypted server-side key backup
--
-- Stores the same Argon2id-wrapped private key that already lives in local
-- storage (crypto_service.dart's WrappedSecret) so a new device — or a
-- cleared browser storage — can recover the identity key (and therefore
-- chat history) from the account password, instead of a fresh keypair being
-- generated and the old history becoming permanently unreadable.
--
-- Server-side, this is still only ciphertext: the account password itself
-- is never stored (Supabase Auth only keeps its hash), so a stolen
-- `key_backups` row is useless without it.
--
-- Deliberately a separate table from `profiles`, not a column on it:
-- `profiles` has a blanket "readable by any authenticated user" policy
-- (needed for people-search), which would otherwise leak every user's
-- wrapped key backup to every other user.

drop table if exists key_backups cascade;

create table key_backups (
  user_id uuid primary key references profiles(id) on delete cascade,
  wrapped_salt text not null,
  wrapped_nonce text not null,
  wrapped_ciphertext text not null,
  updated_at timestamptz not null default now()
);

alter table key_backups enable row level security;

create policy "key backup owner select"
  on key_backups for select
  using (auth.uid() = user_id);

create policy "key backup owner insert"
  on key_backups for insert
  with check (auth.uid() = user_id);

create policy "key backup owner update"
  on key_backups for update
  using (auth.uid() = user_id);
