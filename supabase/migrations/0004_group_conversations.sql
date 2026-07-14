-- Albine Messenger — M2: create a group conversation atomically
--
-- Mirrors create_direct_conversation (0001_init.sql): conversation_members'
-- insert policy only allows inserting your own row, or a row in a
-- conversation you're already admin/owner of — at creation time no owner
-- row exists yet, so a plain client-side sequence of inserts can't add the
-- *other* members. This SECURITY DEFINER function creates the conversation
-- and every member row (including the creator, as 'owner') in one
-- transaction.
--
-- The group key itself is generated and sealed per-member entirely
-- client-side (crypto_service.dart's generateGroupKey/sealGroupKeyForMember)
-- — this function only ever handles already-sealed ciphertext, never the
-- plaintext group key. Unlike create_direct_conversation there's no dedup:
-- creating multiple groups with the same members is fine/expected.

drop function if exists create_group_conversation(text, jsonb);

create or replace function create_group_conversation(title text, members jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
  m jsonb;
begin
  insert into conversations (kind, title, created_by) values ('group', title, auth.uid())
  returning id into new_id;

  for m in select * from jsonb_array_elements(members)
  loop
    insert into conversation_members (conversation_id, user_id, role, wrapped_group_key)
    values (
      new_id,
      (m->>'user_id')::uuid,
      case when (m->>'user_id')::uuid = auth.uid() then 'owner' else 'member' end,
      m->>'wrapped_key'
    );
  end loop;

  return new_id;
end;
$$;
