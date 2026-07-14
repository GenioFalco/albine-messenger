# PROGRESS.md

Session-level working log. Updated before major stages and at least every 30–40 min. For milestone-level plan see `ROADMAP.md`.

---

## 2026-07-13

**Status:** M1.5 fully implemented (both phases) and passes `flutter analyze` clean. Not yet verified live — the Supabase project this app points to (`.env` → `aeblseyhjxkxbqicxxhj.supabase.co`) does not have migrations `0002`/`0003` applied yet (no Supabase CLI/service-role credentials available in this environment to apply them), and the Browser-pane tooling in this environment can't screenshot/click into this app's canvaskit-rendered Flutter Web build (screenshot calls hang), so manual E2E per `ROADMAP.md`'s M1.5 section still needs to happen with real credentials/a real browser.

**Changed files this session:**
- `supabase/migrations/0002_key_backup.sql` (new) — `key_backups` table, owner-only RLS.
- `supabase/migrations/0003_signal_prekeys.sql` (new) — `signed_prekeys`/`one_time_prekeys` tables, `claim_one_time_prekey` RPC, `profiles.signal_registration_id`, `messages.protocol`/`signal_message_type`, `messages.nonce` now nullable.
- `lib/data/key_backup_repository.dart` (new), `lib/data/signal_directory_repository.dart` (new).
- `lib/services/signal/signal_local_store.dart` (new) — `SignalProtocolStore` impl over `shared_preferences`.
- `lib/services/signal/signal_service.dart` (new) — bootstrap/rotate/top-up prekeys, `encryptForContact`/`decryptFromContact`.
- `lib/data/session_controller.dart` — `unlock()`/`setUpProfile()` now try the server key backup before fresh-keygen, and fire-and-forget `_bootstrapSignal(...)` once ready; `resetLocalKeyAndUnlock` passes `trustServerBackup: false`.
- `lib/data/chat_repository.dart` — `sendDirectMessage`/`decryptText` branch on `protocol`; `_signalDecryptCache` (incoming, prewarmed async before the UI reads it) and `_sentSignalEcho` (my own sent plaintext, now persisted to `shared_preferences` via `_rememberSentEcho`/`_ensureEchoLoaded`, capped at 500 entries — survives a page reload; still per-device only, same as every other local key material in this app).
- `lib/domain/models.dart` — `AppProfile.signalRegistrationId`, `ChatMessage.protocol`/`signalMessageType`, `ChatMessage.nonce` now nullable.
- `lib/data/providers.dart` — `keyBackupRepositoryProvider`, `signalDirectoryRepositoryProvider`, `signalServiceProvider`; `chatRepositoryProvider` now requires a non-null `signalServiceProvider`.
- `lib/features/chat/chat_screen.dart` — `sendDirectMessage` call now passes `peer` (AppProfile) instead of `peerPublicKey`.
- `pubspec.yaml` — added `libsignal_protocol_dart: ^0.8.2`.
- `ROADMAP.md` — M1.5 marked done-pending-verification with implementation notes; "Приняты сознательно" trimmed to the real remaining gaps (group key rotation, own-message echo cache, no safety-number verification).
- `../CLAUDE.md`, `PROGRESS.md` — from the previous update (progress-tracking rule, this file).

**Next steps:**
1. Apply `supabase/migrations/0002_key_backup.sql` and `0003_signal_prekeys.sql` to the live Supabase project (SQL Editor or `supabase db push` — no CLI link/credentials available in this environment).
2. Manual E2E per `ROADMAP.md`'s M1.5 section: new-device key restore (right + wrong password), and two-account forward-secrecy exchange (protocol='signal' rows, ratchet surviving a reload, graceful crypto_box fallback when a peer hasn't bootstrapped).
3. Once verified, flip the ROADMAP.md M1.5 heading from "ждёт применения миграций" to fully done.

---

## 2026-07-14

**Status:** M2 (group chats) implemented per the approved plan and passes `flutter analyze` clean. Same verification blocker as M1.5: no Supabase credentials in this environment to apply the new migration, and the Browser-pane tooling can't drive this app's canvaskit-rendered Flutter Web build — manual E2E still pending.

**Changed files this session:**
- `supabase/migrations/0004_group_conversations.sql` (new) — `create_group_conversation` RPC (`security definer`, same pattern as `create_direct_conversation`): creates the conversation + every member row (creator as `'owner'`) atomically from a client-built `{user_id, wrapped_key}` array.
- `lib/domain/models.dart` — `ConversationSummary.members` (nullable list, group-only counterpart to `peer`).
- `lib/data/chat_repository.dart`:
  - Fixed a latent bug exposed by adding real groups: `fetchConversations()` was collapsing all "other members" into a single map entry per conversation (last row wins) — harmless while only 1:1 chats existed, wrong for groups. Now groups into `Map<String, List<AppProfile>>`, split into `peer` (direct) vs `members` (group). Same split added to `fetchConversationSummary()`, which previously had no `else` branch for groups at all.
  - New `_groupKeyCache`/`_tryGroupKeyFor`/`_prewarmGroupKey` — unseal-once-and-cache each group's symmetric key, same async-prewarm-before-sync-decrypt shape as the existing Signal cache. Wired into `watchMessages()`'s `asyncMap` and `fetchConversations()`.
  - `decryptText()` — new `kind == group` branch (checked first) using `crypto_service.dart`'s already-existing `decryptGroupMessage`.
  - New `startGroupConversation()` (calls the RPC) and `sendGroupMessage()` (uses `encryptGroupMessage`; `protocol` column left at its default since `kind` alone already disambiguates group vs 1:1 rows).
- `lib/features/chat/chat_screen.dart` — removed the "Групповые чаты появятся позже" block; `_send()` branches on `kind`; AppBar title gets a "N участников" subtitle for groups.
- `lib/features/conversations/new_group_sheet.dart` (new) — mirrors `new_chat_sheet.dart`: group-name field + multi-select member search (reuses `ProfileRepository.searchProfiles`, filters out already-picked ids locally) + a create button that generates the group key, seals it for every selected member **and self**, and calls `startGroupConversation`.
- `lib/features/conversations/conversations_screen.dart` — added a second "new group" icon button (desktop header + mobile app bar) wired to the new sheet.
- `ROADMAP.md` — M2 marked done-pending-verification; "Приняты сознательно" updated (member-add/key-rotation and no-forward-secrecy-for-groups are the real remaining v1 gaps now).

**Next steps:**
1. Apply `supabase/migrations/0004_group_conversations.sql` (plus the still-outstanding `0002`/`0003` from M1.5) to the live Supabase project.
2. Manual E2E: create a group with 2+ members, confirm all members see it with the right name/participant count, exchange messages both directions, confirm existing 1:1 chats still work unaffected by the `fetchConversations()`/`decryptText()` changes.
3. Once verified, flip both ROADMAP.md M1.5 and M2 headings to fully done.
