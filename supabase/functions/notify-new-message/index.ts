// Sends a Web Push notification to every *other* member of a conversation
// whenever a new message row is inserted. Triggered by a Database Webhook
// (see supabase/migrations/0012_push_notifications.sql) rather than polling.
//
// Strict E2E note: this function only ever sees ciphertext (the `messages`
// row) — it has no way to know what the message says, and deliberately
// makes no attempt to. The notification body is always the same generic
// "Новое сообщение" (see ROADMAP.md's M4 "развилка" — this was decided, not
// a placeholder to fill in later: showing real text would require the
// server to read plaintext, which breaks the whole point of E2E).
//
// Deploy: `supabase functions deploy notify-new-message`
// Secrets (set once): `supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:you@example.com`
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically by
// the Edge Functions runtime — no need to set those two yourself.)

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

if (VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY) {
  webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);
}

Deno.serve(async (req) => {
  if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY) {
    // Not configured yet — accept the webhook call as a no-op rather than
    // erroring the DB trigger that invoked it (see the migration's retry
    // notes on net.http_post).
    return new Response("push not configured", { status: 200 });
  }

  let payload: { record?: { conversation_id?: string; sender_id?: string } };
  try {
    payload = await req.json();
  } catch {
    return new Response("bad request", { status: 400 });
  }

  const message = payload.record;
  if (!message?.conversation_id || !message?.sender_id) {
    return new Response("ok", { status: 200 });
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: members } = await supabase
    .from("conversation_members")
    .select("user_id")
    .eq("conversation_id", message.conversation_id)
    .neq("user_id", message.sender_id);

  const recipientIds = (members ?? []).map((m: { user_id: string }) => m.user_id);
  if (recipientIds.length === 0) {
    return new Response("ok", { status: 200 });
  }

  const { data: subs } = await supabase
    .from("push_subscriptions")
    .select("*")
    .in("user_id", recipientIds);

  const body = JSON.stringify({
    title: "Albine",
    body: "Новое сообщение",
    url: "./",
  });

  await Promise.all(
    (subs ?? []).map(async (s: { id: string; endpoint: string; p256dh: string; auth_key: string }) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } },
          body,
        );
      } catch (err) {
        // 404/410 = the browser/OS dropped this subscription (uninstalled,
        // cleared data, etc.) — clean it up instead of retrying forever.
        const status = (err as { statusCode?: number })?.statusCode;
        if (status === 404 || status === 410) {
          await supabase.from("push_subscriptions").delete().eq("id", s.id);
        }
      }
    }),
  );

  return new Response("ok", { status: 200 });
});
