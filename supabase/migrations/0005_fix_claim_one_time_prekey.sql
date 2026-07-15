-- Fixes claim_one_time_prekey (0003_signal_prekeys.sql): RETURNS TABLE(key_id
-- int, ...) implicitly declares `key_id` as an OUT parameter scoped to the
-- whole function body, so the unqualified `key_id` in the DELETE's WHERE
-- clause was ambiguous between that parameter and the table column —
-- Postgres error 42702 ("column reference \"key_id\" is ambiguous"). This
-- silently broke every attempt to claim a one-time prekey, i.e. every fresh
-- X3DH handshake, which is likely behind most of the "не удалось
-- расшифровать" failures seen throughout M1.5 testing, not just the two
-- crashes it was root-caused from today.
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

  delete from one_time_prekeys o where o.user_id = target_user_id and o.key_id = rec.key_id;
  return query select rec.key_id, rec.public_key;
end;
$$;
