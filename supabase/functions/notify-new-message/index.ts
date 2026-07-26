// Sends a Web Push notification to every *other* member of a conversation
// whenever a new message row is inserted. Triggered by a Database Webhook
// (see supabase/migrations/0012_push_notifications.sql) rather than polling.
//
// Strict E2E note: this function only ever sees ciphertext (the `messages`
// row) — it has no way to know what the message *says*, and deliberately
// makes no attempt to. The notification *body* is therefore always the
// generic "Новое сообщение" (see ROADMAP.md's M4 "развилка" — decided, not a
// placeholder: showing the real text would require the server to read
// plaintext, breaking the whole point of E2E).
//
// The *title*, however, is public metadata the server legitimately knows:
// who sent it (their display name) and, for a group, the group's name —
// none of which is message content. So the notification reads e.g.
// "Женя" / "Новое сообщение" for a direct chat, or
// "Женя • Команда RPA" / "Новое сообщение" for a group. That's the most a
// strict-E2E messenger can show, and matches what Signal itself does.
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

  // Public metadata only (never message content): the sender's display name,
  // and — for a group — the group's title. See the E2E note at the top.
  const { data: sender } = await supabase
    .from("profiles")
    .select("display_name")
    .eq("id", message.sender_id)
    .maybeSingle();

  const { data: conversation } = await supabase
    .from("conversations")
    .select("kind, title")
    .eq("id", message.conversation_id)
    .maybeSingle();

  const senderName = sender?.display_name ?? "Albine";
  const title =
    conversation?.kind === "group" && conversation?.title
      ? `${senderName} • ${conversation.title}`
      : senderName;

  // The actual Web Push subscriptions to deliver to — one row per device each
  // recipient has enabled notifications on.
  const { data: subs } = await supabase
    .from("push_subscriptions")
    .select("id, endpoint, p256dh, auth_key")
    .in("user_id", recipientIds);

  if (!subs || subs.length === 0) {
    return new Response("ok", { status: 200 });
  }

  const body = JSON.stringify({
    title,
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
