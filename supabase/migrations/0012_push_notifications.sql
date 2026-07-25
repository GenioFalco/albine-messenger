-- Push notifications (M4): fires the `notify-new-message` edge function
-- (supabase/functions/notify-new-message/) on every new message, via
-- pg_net — Supabase's supported way to call an HTTP endpoint from a
-- trigger, no external cron/polling needed.
--
-- SETUP (do this once, after deploying the edge function — the URL/key
-- below can't be hardcoded in this file since it's committed to git):
--
--   1. supabase functions deploy notify-new-message
--   2. supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:you@example.com
--      (generate a keypair first, e.g. `npx web-push generate-vapid-keys`;
--      the public half also goes in this app's own .env as VAPID_PUBLIC_KEY)
--   3. In the SQL editor, run (fill in your own project ref + service_role
--      key from Project Settings → API):
--        alter database postgres set app.settings.edge_function_url to
--          'https://<project-ref>.supabase.co/functions/v1/notify-new-message';
--        alter database postgres set app.settings.service_role_key to
--          '<service_role key>';
--      Start a *fresh* SQL editor session afterwards — ALTER DATABASE SET
--      only takes effect for new connections.
--
-- Until step 3 is done this trigger is a harmless no-op (it checks for an
-- empty setting and returns immediately, logging nothing).
create extension if not exists pg_net with schema extensions;

create or replace function notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  edge_url text := current_setting('app.settings.edge_function_url', true);
  service_key text := current_setting('app.settings.service_role_key', true);
begin
  if edge_url is null or edge_url = '' then
    return new;
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
