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

---

## 2026-07-14 (later) — M1.5-fix: concurrency regression, session persistence, key rotation

**Status:** Live testing (finally in a real browser, migrations already applied by the user) surfaced a serious regression from M1.5: signing out and back in broke decryption for **both** parties in a conversation. Root-caused via a dedicated investigation, then fixed along with two features the user asked for during the resulting design discussion. Passes `flutter analyze` clean; rebuilt (`flutter build web`) and the local preview server restarted on the fresh build.

**Root cause:** `SignalLocalStore` stores every contact's Double Ratchet session in one shared JSON blob per user, read-modify-written with no locking. `watchConversations()`'s and `watchMessages()`'s independent async prewarm pipelines (`chat_repository.dart`) could both touch that blob concurrently, especially right after a sign-in burst — a lost update desyncs the ratchet, and because message keys are deleted immediately after use (forward secrecy working as designed), the desync is unrecoverable and cascades to the other party's device too.

**Changed files:**
- `lib/services/signal/signal_service.dart` — every operation touching a contact's session (or the account's own prekey bootstrap) now goes through a `static` keyed lock (`_withLock`/`_locks`) so concurrent callers queue instead of racing. `static` deliberately, not per-instance — `session_controller.dart`'s `_bootstrapSignal` constructs its own separate `SignalService` from the one `signalServiceProvider` hands `ChatRepository`, and both must serialize against the same lock. New `resetSessionWith(contactId)` — deletes a contact's local session so the next message triggers a fresh handshake (self-healing after a decrypt failure) — and `ensureBootstrapped` is now awaited (not fire-and-forget) inside `rotateIdentityKey`.
- `lib/data/chat_repository.dart` — `_prewarmSignalDecryption`'s catch block calls `resetSessionWith` before caching the failure. New `_groupKeyFailed` set gives group decryption a real failure state instead of "Расшифровка…" forever. New retired-key decrypt fallback for `protocol: 'crypto_box'` (tries `KeyStorage.loadRetiredSecretKeys` in order after the current key fails) — needed so history stays readable after a key rotation; constructor now takes `KeyStorage`.
- `lib/services/crypto/key_storage.dart` — `saveUnlockedSecretKey`/`loadUnlockedSecretKey`/`clearUnlockedSecretKey` (the session-persistence cache) and `addRetiredSecretKey`/`loadRetiredSecretKeys` (capped at 10, local-only, for the rotation feature).
- `lib/services/crypto/crypto_service.dart` — `wrapSecureKey()`, wraps raw bytes as a `SecureKey` without `restoreIdentityKeyPair`'s public-key match check (retired keys don't match the *current* public key by definition).
- `lib/services/signal/signal_local_store.dart` — `resetAll()`, full wipe of one user's Signal state (identity, prekeys, all sessions) for the rotation feature.
- `lib/data/session_controller.dart` — `_refresh()` checks the unlocked-key cache before ever asking for a password; `unlock()`/`setUpProfile()` populate it on every success path; `signOut()` clears it (the only thing that re-triggers the password prompt, and it doesn't lose history — the server backup is untouched). New `rotateIdentityKey(password)`: re-verifies the password, archives the current key locally, generates+publishes a new one, re-backs it up server-side, fully resets Signal state, and re-bootstraps.
- `lib/features/profile/profile_screen.dart` — new "Безопасность" section: explanatory copy + a "Сбросить ключ шифрования" action opening a password-confirm dialog (`_RotateKeyDialog`) that calls `rotateIdentityKey`.
- `ROADMAP.md` — M1.5 section extended with points 3–5 (concurrency fix, session persistence, key rotation) and the reasoning behind each trade-off.

**Next steps:**
1. Manual E2E in a real browser (already the plan going forward — this environment's browser tooling can't drive canvaskit): two accounts messaging continuously while alternating sign-out/in and reloads on one side, confirming no desync; a rotate-key action confirming old messages stay readable and new messages work for both parties afterward.
2. If clean, this closes out the M1.5 regression — no further known gaps before M3.
