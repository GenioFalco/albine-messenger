-- Push notifications (M4): fires the `notify-new-message` edge function
-- (supabase/functions/notify-new-message/) on every new message, via
-- pg_net — Supabase's supported way to call an HTTP endpoint from a
-- trigger, no external cron/polling needed.
--
-- The function URL and service-role key are read from Supabase Vault
-- rather than `ALTER DATABASE ... SET` — the SQL editor's role isn't
-- allowed to set arbitrary database-level GUCs on a hosted project
-- ("permission denied to set parameter"), but it *can* write to Vault,
-- which is exactly what Vault is for.
--
-- SETUP (do this once, after deploying the edge function — see that
-- folder's own doc comment for the deploy/secrets steps). Run this in the
-- SQL editor with your own values (never commit real values to this file):
--
--   select vault.create_secret(
--     'https://<project-ref>.supabase.co/functions/v1/notify-new-message',
--     'edge_function_url'
--   );
--   select vault.create_secret(
--     '<service_role key, from Project Settings -> API>',
--     'service_role_key'
--   );
--
-- Until both secrets exist this trigger is a harmless no-op (it checks for
-- a missing secret and returns immediately). To update either value later,
-- delete the old secret from Table Editor -> vault.secrets and re-run the
-- corresponding vault.create_secret call above.
create extension if not exists pg_net with schema extensions;

create or replace function notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  edge_url text;
  service_key text;
begin
  select decrypted_secret into edge_url
    from vault.decrypted_secrets where name = 'edge_function_url';
  select decrypted_secret into service_key
    from vault.decrypted_secrets where name = 'service_role_key';

  if edge_url is null or service_key is null then
    return new; -- not configured yet — see setup note above
  end if;

  perform net.http_post(
    url := edge_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || service_key
    ),
    body := jsonb_build_object('record', row_to_json(new))
  );
  return new;
end;
$$;

drop trigger if exists on_message_insert_notify on messages;
create trigger on_message_insert_notify
  after insert on messages
  for each row execute function notify_new_message();
