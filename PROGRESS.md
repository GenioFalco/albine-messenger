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

---

## 2026-07-14 (later still) — rotate-key/groups crash + silent send failures

**Status:** Live testing surfaced a second regression, this time in "Сбросить ключ шифрования": rotating the identity key never re-sealed this device's copy of each group's symmetric key, so every group became permanently undecryptable (`crypto_box_seal_open` throwing, since the seal is bound to the public key active when it was sealed). Separately, `chat_screen.dart`'s send button had no error handling at all — a thrown error silently cleared the typed message with zero feedback, which is how the above surfaced as "typed a message, nothing happened."

**Changed files:**
- `lib/data/session_controller.dart` — `rotateIdentityKey` now re-seals every group key this device holds from the old public key to the new one before the old keypair is disposed (`_reSealGroupKeys`, best-effort per group so one bad row doesn't abort the rotation).
- `lib/features/chat/chat_screen.dart` — `_send()` now catches errors, restores the typed text, and shows a `SnackBar` via `humanizeError` instead of failing silently.

**Open issue (found and fixed):** a second, distinct `SodiumException` was reported from a *direct* (1:1) conversation — confirmed not the group-reseal bug (that path only runs for `sendGroupMessage`). The user found the real cause themselves in the DevTools console: `claim_one_time_prekey` (`supabase/migrations/0003_signal_prekeys.sql`) was throwing `PostgrestException: column reference "key_id" is ambiguous` (Postgres 42702) on every call — `RETURNS TABLE(key_id int, ...)` implicitly declares `key_id` as an OUT parameter scoped to the whole function body, and the DELETE's unqualified `key_id` in its WHERE clause was ambiguous against that. This has likely been silently breaking *every* fresh X3DH handshake since 0003 was applied — plausibly the real cause of much of the "не удалось расшифровать" noise seen throughout M1.5 testing, not just today's two crash reports.

**Fix:**
- `supabase/migrations/0005_fix_claim_one_time_prekey.sql` (new) — re-`create or replace`s the function with the DELETE's `key_id` qualified to the table alias. **Needs to be applied to the live Supabase project (SQL Editor) — not done yet.**
- `lib/data/signal_directory_repository.dart` — `fetchBundle()`'s prekey-claim RPC call is now wrapped in try/catch, degrading to "no one-time prekey" (still a valid, if slightly weaker, X3DH session) instead of aborting the whole handshake — defense in depth so a future transient RPC failure can't take down sending the same way.

**Next steps:**
1. Apply `0005_fix_claim_one_time_prekey.sql` to the live Supabase project.
2. Re-test sending in both the direct chat and the group chat that failed.
3. Re-run the full M1.5 manual E2E checklist above now that this root cause is fixed.

**Known limitation found during this round (not a bug, not fixed):** signing into the same account from two devices (phone + PC) at once, each builds its own independent Double Ratchet session per contact — a message encrypted on one device's ratchet chain can't be decrypted by the other's. Real WhatsApp/Signal solve this with proper multi-device (each device is a distinct registered `deviceId`, sender fans out ciphertext to every device including its own others). User chose to defer this — see ROADMAP.md "Приняты сознательно" — current model is effectively single-active-device for live forward-secret messaging; server-side key backup still restores everything on a new device, it just doesn't *live-sync* between two devices used simultaneously.

---

## 2026-07-15 — UI overhaul: unified new-chat button, chat list actions, message actions

**Status:** User paused M3 (media) to request a UI/UX pass instead: one unified "new conversation" entry point, swipe/long-press actions on the conversation list (pin/mute/delete), and per-message actions (reply/edit/pin/delete/forward) in the chat screen. Implemented in full; `flutter analyze` clean, `flutter build web` succeeds. Not yet manually tested in a real browser.

**New migration:** `supabase/migrations/0006_conversation_message_actions.sql` — adds `conversation_members.pinned_at/muted/hidden_at` (per-user chat prefs, no RLS changes needed — already covered by the existing "update own membership row" policy) and `messages.reply_to_id/pinned_at/forwarded_from_sender_id/edits_message_id`, plus a `toggle_message_pin` RPC (any member can pin/unpin, but the RPC only ever touches `pinned_at` — can't be used to smuggle a content change into someone else's message). **Needs to be applied to the live Supabase project — not done yet, same as 0005.**

**Design note on editing:** a `protocol: 'signal'` message's ciphertext can't be overwritten in place after the fact — that message's one-time key is already discarded (forward secrecy working as intended, the same reason outgoing signal messages need the local sent-echo cache). So an edit is implemented as its own new encrypted message (`edits_message_id` pointing at the target), applied client-side as a text override for the target's display rather than rendered as a separate bubble — this is how real Signal/WhatsApp edits work too, not a shortcut.

**Changed files:**
- `pubspec.yaml` — added `flutter_slidable` for the conversation-list swipe actions.
- `lib/domain/models.dart` — `ConversationSummary` gains `pinnedAt`/`muted`/`hiddenAt` (+ `isPinned`/`isHidden` getters); `ChatMessage` gains `deletedAt`/`replyToId`/`pinnedAt`/`forwardedFromSenderId`/`editsMessageId` (+ `isEditEvent`).
- `lib/data/chat_repository.dart` — `_editOverrides` cache + `_applyEditEvents`/`applyEditEvents` (resolves edit-event rows to text overrides, strips them from the visible list); `fetchConversations()` now selects/returns pin/mute/hidden state, filters hidden conversations (reappear once a newer message arrives), sorts pinned-first, and folds the latest edit into the preview if it targets the last message; `setConversationPinned`/`setConversationMuted`/`hideConversation`; `sendDirectMessage`/`sendGroupMessage` take optional `replyToId`/`editsMessageId`/`forwardedFromSenderId`; new `forwardMessage`, `fetchPinnedMessage`, `toggleMessagePin`, `deleteMessage` (scrubs ciphertext server-side, not just a flag); `decryptText` checks `deletedAt`/`_editOverrides` first.
- `lib/features/conversations/conversations_screen.dart` — the two icon buttons became one ("+") opening a sheet to choose direct vs group; `_ConversationTile` wrapped in `Slidable` (swipe right: pin, swipe left: mute + delete) with a long-press sheet offering the same three actions; pin/mute indicators in the tile.
- `lib/features/chat/chat_screen.dart` — long-press a message for an action sheet (Reply/Edit[own]/Pin/Forward/Delete[own]); reply shows a quoted preview inside the bubble and a composer strip above the input; edit pre-fills the input and swaps the send icon to a checkmark; deleted messages render as a tombstone; forwarded messages show "Переслано от X"; a pinned-message banner sits above the message list. New `_ForwardPickerSheet` (reuses the conversations stream) for picking a forward target.

**Next steps:**
1. Apply `0006_conversation_message_actions.sql` to the live Supabase project (along with the still-outstanding `0005`).
2. Manual E2E in a real browser: swipe/long-press chat-list actions, reply/edit/pin/forward/delete in a direct chat and a group chat, confirm a hidden chat reappears on a new incoming message, confirm an edited message's preview updates in the conversation list.

**Same-day follow-up:** added per-message HH:mm timestamps and day separators ("Сегодня"/"Вчера"/DD.MM.YYYY) in the chat screen, matching VK/WhatsApp-style grouping — `lib/core/format.dart` (`formatMessageTime`, `formatDateSeparator`), `lib/features/chat/chat_screen.dart` (`_ChatListEntry`/`_buildListEntries` interleaves separators between message bubbles; each bubble now shows its time bottom-right). `flutter analyze` clean, `flutter build web` succeeds.

**Bug found in that follow-up, fixed same day:** the per-message time `Text` was wrapped in an unconstrained `Align`, which expands to fill all available width unless bounded — every bubble stretched to the full 75%-of-screen max-width constraint regardless of actual text length, and the time ended up stranded at the far right of the resulting empty space. Replaced with a plain `Text` (no `Align`) so bubbles hug their content again and the time sits naturally under it.

**Follow-up 2 — sheet styling + multi-select:** user asked for the action sheets to look like WhatsApp/Telegram/iOS (blurred background, matching icon pack) and for a "Выбрать" (multi-select) message mode.
- `lib/shared/widgets/app_widgets.dart` — new `showBlurredModalSheet()` (full-screen `BackdropFilter` blur behind a transparent-backed modal route, vs. `showModalBottomSheet`'s flat scrim) and `ActionSheetTile` (shared icon+label row, optional destructive/red styling) — both reused across the message action sheet, conversation tile menu, new-conversation picker, and forward picker.
- Icons switched from Material to `CupertinoIcons` throughout these menus/sheets (reply, copy, pencil, pin/pin_slash, arrowshape_turn_up_right, delete, checkmark_circle, bell/bell_slash, person/person_2) to match the iOS-style pack WhatsApp/Telegram use — `cupertino_icons` was already a dependency, just unused until now.
- `lib/features/chat/chat_screen.dart` — new "Выбрать" tile enters multi-select mode: tapping a bubble toggles a leading checkmark-circle instead of opening the action sheet, the `AppBar` swaps to a "N выбрано" toolbar with forward-selected/delete-selected actions and an X to exit. Forwarding selected messages reuses `forwardMessage` per item (decrypted locally, re-encrypted for the target); deleting reuses `deleteMessage` per item (RLS silently no-ops on anything not mine, so a mixed selection only removes my own).

**Follow-up 3 — sheet looked like a full sheet, not a floating card; tap-outside didn't dismiss.** Root cause: `showBlurredModalSheet` stretched the sheet's own hit-testable area to the full screen (to get a full-background blur via `BackdropFilter`), which meant it now covered the same area the framework's own "tap outside to dismiss" barrier would otherwise catch — only the sheet's built-in swipe-down still worked. Rebuilt on `showGeneralDialog` instead of `showModalBottomSheet`: `barrierDismissible: true` gives tap-anywhere-to-close for free, the card itself is now width-constrained (`maxWidth`, 300 default / 420 for the forward picker) so it reads as a floating panel like the reference screenshot instead of edge-to-edge, and the blur is lighter (sigma 6, fading in with the open animation, vs. the previous flat 20) per request. Same signature, so no call-site changes beyond the forward picker passing a wider `maxWidth`.

**Bug found testing that follow-up: every sheet rendered as an empty flat gray box.** `showModalBottomSheet` automatically wraps its content in a `Material` ancestor; `showGeneralDialog` does not. Every sheet's content has a `ListTile`/`InkWell` somewhere (`ActionSheetTile`, the forward picker's list), and both require a `Material` ancestor — without one Flutter throws "No Material widget found" during build, which a release build (no debug banner) renders as `ErrorWidget`'s default plain gray box instead of visible error text, on every platform (reproduced identically on desktop Chrome and iOS Safari). Fixed by wrapping the card in `Material(type: MaterialType.transparency, ...)` inside `showBlurredModalSheet` itself, so every call site is covered without changes.

**Follow-up 4 — tapping empty space still didn't dismiss; wanted blur on mobile only.** Root cause of the dismiss bug: a `ColoredBox`/`BackdropFilter` veil is opaque to hit-testing over its *entire* area even where it paints "nothing new" — wrapping it around the whole page (dim veil behind, card in front, as one nested tree) meant that veil intercepted every tap, including ones meant to fall through to the dialog's own barrier below and dismiss it; only the sheet's card itself (via its own `InkWell`s) ever got a tap. Fixed by making the veil and the card *siblings* in a `Stack` instead of parent/child: the veil is `Positioned.fill` with its own explicit `onTap: Navigator.pop`, and the card — painted after it — still claims taps within its own bounds first. Also, per request, the blur/dim now only applies below `main_shell.dart`'s existing 900px mobile/desktop breakpoint; on desktop the card floats over a completely sharp, unmodified background, matching the Telegram-desktop reference screenshot exactly.

**Follow-up 5 — Telegram-style message preview, tombstone removal, forwarded-edit bug, composer redesign.**
- `_showMessageActions` now shows a small copy of the long-pressed message (same bubble color/shape) above the actions card, matching Telegram's long-press menu — previously it was just the menu with no context.
- Deleted messages are now dropped entirely from `_buildListEntries` rather than rendered as a "🗑 Сообщение удалено" placeholder — a deleted message just isn't there any more, same as Telegram (not WhatsApp's tombstone style).
- Fixed a real bug: a forwarded message showed "Редактировать" whenever I was the one who forwarded it (`mine == true`), even though I didn't author its content. Now gated on `forwardedFromSenderId == null` too.
- Composer redesigned: raised/more padding around the input; a disabled paperclip icon on the left (placeholder for M3 media, not wired up); the trailing button now toggles between mic/video-camera icons when the input is empty (tap to switch, not functional yet — voice/video isn't implemented) and swaps to a solid circular accent-colored send button (Cupertino arrow-up / checkmark-when-editing) as soon as there's text, replacing the old plain `IconButton.filled`.

**Same-day follow-up:** composer still sat flush against the screen's bottom edge and the mic/camera/paperclip icons looked thin/generic next to Telegram's — bumped the bottom padding (14 → 24) so the bar clears the edge with real breathing room, and swapped `CupertinoIcons.mic`/`videocam` for the bolder filled `mic_fill`/`camera_fill`, with consistent 26px sizing across paperclip/mic/camera.

**Follow-up 6 — camera icon, and two real bugs from live testing.**
- Camera toggle icon switched from `camera_fill` to outline `camera` — the filled glyph loses the lens-circle detail at this size and just reads as a blob; the outline keeps the recognizable "body + lens" camera shape.
- **Bug:** deleting a conversation's most recent message left the chat-list preview stuck on "🗑 Сообщение удалено" instead of falling back to whatever real message precedes it — `fetchConversations()`'s last-message picker only skipped edit-event rows, not deleted ones. Fixed by skipping `deletedAt != null` there too.
- **Change:** messages are now hard-deleted (`deleteMessage()` calls `.delete()`, not a soft-delete update) — there's no reason for a deleted message's row to linger in the database at all. New `supabase/migrations/0007_hard_delete_messages.sql` adds the DELETE RLS policy (`messages` only had UPDATE before, for the old soft-delete/edit approach) and one-off cleans up any rows already soft-deleted under the old scheme. `ChatMessage.deletedAt`/the `decryptText`/`_buildListEntries` skip-if-deleted checks stay in place defensively (a stale cached client build could still soft-delete for a while after this deploys), just no new row should ever get `deleted_at` set going forward.

**Follow-up 7 — group sender identity, scroll-to-message, anchored long-press menu.**
- **Group sender name + avatar:** a group message from someone else now shows their display name (accent-colored, above the bubble) and a small circle avatar beside it — previously the only cue was bubble side/color, ambiguous once a group has 3+ people. Own messages and all direct-chat messages are unaffected (identity is already obvious there).
- **Pinned-message banner redesign:** was a plain unstyled row that didn't visibly react to taps; now a proper Telegram-style bar (accent-colored left stripe, "Закреплённое сообщение" label + preview, still has its unpin ✕) and is genuinely tappable — tapping it scrolls to and briefly highlights the pinned message.
- **Reply-quote tap:** tapping the quoted snippet inside a reply now scrolls to and highlights the original message, same mechanism as the pin banner.
- **Scroll-to-message infra** (`_messageKeys`/`_scrollToMessage`/`_highlightedMessageId` in `chat_screen.dart`): a stable `GlobalKey` per rendered message (`ListView.builder` recycles widgets, so these persist across rebuilds in a `Map` rather than being created fresh each build) lets `Scrollable.ensureVisible` jump to any currently-rendered message regardless of item heights; a 300ms highlight tint confirms where it landed. Only works for messages currently in the loaded list — there's no pagination yet, so this doesn't reach further back than what's already fetched.
- **Fixed a latent bug this surfaced:** the message list unconditionally jumped to the bottom on every rebuild (`WidgetsBinding.instance.addPostFrameCallback` ran unconditionally) — harmless before since nothing else ever scrolled programmatically, but it would have silently undone every scroll-to-message the instant the stream re-emitted for any reason (e.g. an unrelated pin/mute toggle touching `conversation_members`). Now only jumps to bottom when the list actually grew (a new message arrived) and no scroll-to-message is in flight.
- **Anchored long-press menu:** `showBlurredModalSheet` takes an optional `anchorRect` (+ `anchorAlignRight` to match the bubble's side) — the message action sheet passes the long-pressed bubble's actual on-screen rect (via its `GlobalKey`'s `RenderBox`), and the card now floats directly below it (or above, if there isn't room below) instead of always sitting bottom-center. The preview-bubble copy shown above the menu already reads as "the real message, still visible" against the blurred rest of the screen — no change needed there, just the positioning.

**Next steps:**
1. Apply `0005`/`0006`/`0007` migrations to the live Supabase project (still outstanding).
2. Manual E2E: group chat shows sender name/avatar correctly, pin banner + reply-quote scroll-to-message and highlight, long-press menu appears near the pressed message (above vs below near screen edges) without breaking tap-to-dismiss, message list still auto-scrolls to bottom on new messages.
