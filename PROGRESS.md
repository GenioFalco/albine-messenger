# PROGRESS.md

Session-level working log. Updated before major stages and at least every 30–40 min. For milestone-level plan see `ROADMAP.md`.

---

## 2026-07-28 — Голосовые: ML-шумодав RNNoise (WASM)

**Status:** Базовая Web Audio цепочка «почти ничего не изменила» по фону, поэтому добавлен настоящий ИИ-шумодав **RNNoise**. Пайплайн проверен прямо в браузере через JS-консоль (canvaskit-UI недоступен, но RNNoise — чистый JS/WASM, проверяется независимо): `createRNNWasmModule`=function, `albineDenoise` реально обрабатывает (~59 мс на 1 сек аудио, RMS 0.157→0.096 — шум давится). Осталась живая проверка на слух на реальной записи.

- **Ассеты:** `web/rnnoise.js` (emscripten glue) + `web/rnnoise.wasm` (110 КБ, sha256 сверен с реестром jsdelivr — подлинный) + `web/rnnoise_denoise.js` (обёртка). Взято из `@jitsi/rnnoise-wasm@0.2.1`.
- **Важный баг при интеграции:** upstream `rnnoise.js` заканчивается `export default createRNNWasmModule;` → это ES-модуль, и классический `<script>` падает с SyntaxError (фабрика не определяется, денойз молча откатывался за 1 мс). Убрал эту строку из вендоренного `web/rnnoise.js` → грузится классическим скриптом, `createRNNWasmModule` — глобаль.
- **Обёртка** `window.albineDenoise(Float32Array, sampleRate) → Promise<Float32Array>`: ресемпл в 48 кГц при необходимости, обработка кадрами по 480 сэмплов (сэмплы масштабируются в int16-диапазон), fail-open (при любой ошибке возвращает оригинал — ГС всё равно уходит). Вся возня с памятью emscripten (malloc/HEAPF32) заперта в JS.
- **Dart:** `audio_recorder.dart` в `stop()` зовёт `albineDenoise` (через `dart:js_interop_unsafe` `globalContext.getProperty`), затем нормализация → WAV@48к. `index.html` грузит оба скрипта.
- Web Audio цепочка (high-pass + компрессор + нормализация + voiceIsolation) осталась перед RNNoise.

---

## 2026-07-27 (2) — M5 этап 2: волна/перемотка/скорость + запись в WAV ради iOS

**Status:** Голосовые доведены до вида и поведения как в ТГ/ВК; отдельно решена проблема «на iPhone не играет вообще ничего». Собрано (`flutter analyze` — чисто в voice-файлах, `build web` — ок). Требует применения миграции `0015` + живой проверки на iPhone (новой записью).

**Вид и управление (`voice_message_bubble.dart`):**
- Волна палочками вместо простого прогресс-бара (`_WaveformPainter`, ~40 столбиков). Волна + точная длительность считаются на устройстве-записи и хранятся (миграция `0015`: `media_duration_ms`, `media_waveform`) → бары и длина видны сразу, без скачивания аудио. Старые/без-метаданных клипы рисуют дефолтный узор.
- Бары = шкала перемотки: тап или слайд перематывает.
- Скорость 1× → 1.5× → 2× (кнопка-пилюля).
- Играет только одно ГС за раз — старт нового ставит предыдущее на паузу (`_VoicePlaybackCoordinator`).

**iPhone не проигрывал НИЧЕГО (даже своё) — причина и фикс:** iOS Safari не декодирует Opus/WebM ни в `<audio>`, ни в Web Audio. Перевёл запись с `record`/Opus на **несжатый 16-бит PCM WAV** через Web Audio (`getUserMedia` → `ScriptProcessorNode`, `audio_recorder.dart` полностью переписан). WAV играют все браузеры включая iOS, и он lossless — самый чистый звук (в тему требования «не как ВК»). Волну и длительность берём прямо из PCM (без decode). Плюс: плеер грузится заранее (`initState`), иначе iOS блокирует `<audio>.play()` после сетевой паузы (теряется user-gesture).

**Модель/репо:** `ChatMessage.mediaDurationMs`/`mediaWaveform`; `sendMediaMessage` принимает `durationMs`/`waveform`; `RecordedVoice` несёт волну. Пакет `record` больше не используется (остался в pubspec, безвреден).

**Осторожно:** старые голосовые в WebM на iPhone так и не заиграют — проверять только новыми записями. Кружки (видео-заметки) по-прежнему в этапе 2/позже.

---

## 2026-07-27 — M5 этап 1: голосовые сообщения (код готов, ждёт живой проверки)

**Status:** Первый из двух этапов M5-ГС. Запись → шифрование → отправка → воспроизведение — сквозной цикл. `flutter analyze` (только предсуществующие infos), `flutter build web --pwa-strategy=none` — чисто, приложение грузится без ошибок в консоли. Живой клик по записи в этой среде не проверить (canvaskit-автоматизация не работает) — нужна ручная проверка.

- **Запись — чистый звук.** Новый `lib/core/audio_recorder.dart` (`VoiceRecorder`) поверх пакета `record`: Opus, 48 кГц, моно, ~96 кбит + echoCancel/noiseSuppress/autoGain. Это радикально выше ~16–24 кбит у ВК/WhatsApp (именно низкий битрейт даёт их «кашу»), Opus на 96к для речи прозрачен — артефактов нет. Веб-only: `record` отдаёт blob-URL на `stop()`, забираем байты через `package:web` fetch.
- **Крипты и изменений в репозитории для отправки не потребовалось** — голосовое идёт через готовый `sendMediaMessage` с `content_type = 'voice'` и mime `audio/webm;codecs=opus`. Тот же per-file AEAD-ключ, запечатанный каждому участнику; сервер видит только шифротекст.
- **Плеер** — новый `lib/features/chat/voice_message_bubble.dart` (`VoiceMessageBubble`) на `just_audio`: лениво (по первому тапу) скачивает+расшифровывает, играет из in-memory blob-URL (плейнтекст на диск не попадает, URL освобождается в dispose), кнопка play/pause + прогресс-бар + время.
- **Поле ввода:** тап по микрофону — старт записи; появляется панель записи (корзина-отмена, красная точка, таймер, синяя кнопка отправки). Долгое нажатие на иконку — переключение мик↔камера (видео-кружки — этап 2).
- **Превью в списке чатов** — «🎤 Голосовое сообщение» (`decryptText`).
- **Зависимости:** `record: ^6.0.0`, `just_audio: ^0.10.0`.
- **Миграций не требуется** (переиспользуются существующие media-колонки). Длительность пока определяется плеером при загрузке; её сохранение в БД + волновая форма — этап 2.

**Этап 2 (потом):** живая волновая форма (при записи и в пузыре), запись удержанием со слайдом-отменой и «замком», скорость 1.5×/2×, длительность/волна в БД, тонкая настройка звука, видео-кружки.

---

## 2026-07-26 (2) — ROOT-CAUSE fix: prekey orphan → permanent "Не удалось расшифровать"

**Status:** Found and fixed the real decrypt bug (the previous entry's "not a code bug, it's test-environment desync" diagnosis was **wrong** — it *is* a code bug, reproducible for real users). Build clean (`flutter analyze` on changed files, `flutter build web --pwa-strategy=none`). Also fixed a broken notification edge function and made read receipts robust.

**The bug — orphaned one-time prekeys.** When a device loses its *local* Signal store (cleared browser data, a **different origin** — the launch config serves at `127.0.0.1:5050` but the preview opens `localhost:5050`, two separate `localStorage` scopes! — or the "rotate key" action), the account's one-time prekeys published to the server survive, but their private halves are gone. `SignalService._topUpOneTimePreKeys()` decides whether to regenerate by the **server** count, so it sees ≥10 prekeys still there and generates nothing → the local store ends up with zero usable one-time prekeys while the server keeps handing peers dead ones. Every X3DH session a peer builds then fails permanently with `InvalidKeyIdException - No such prekey: N` (exactly the 5–10 sequence in the logs — each incoming handshake burns the next dead prekey). This also explains why the user's earlier "reset key" attempts didn't stick: `resetAll()` cleared the local store but bootstrap then skipped prekey regen for the same reason.

**Fix (three layers):**
1. `SignalService.ensureBootstrapped()` — on a *fresh* local store, `deleteAllOwnPreKeys()` on the server first, so the top-up republishes a clean, fully-matching bundle. Makes "rotate key" / clear-data / new-origin self-correct.
2. `SignalService.republishOwnPreKeys()` (new) + wired into `ChatRepository._prewarmSignalDecryption`'s catch: the first time a decrypt fails with `InvalidKeyIdException`, republish a fresh bundle once. Since both sides of a broken chat are usually in the same re-handshake loop, once each republishes the next handshake claims a live prekey and the conversation **self-heals with no manual reset**.
3. `SignalDirectoryRepository.deleteAllOwnPreKeys()` + `0013` migration adds the owner-DELETE RLS policies on `one_time_prekeys`/`signed_prekeys` (0003 never granted delete).

**Read receipts — now via a SECURITY DEFINER RPC.** `markMessagesRead` was a direct UPDATE relying on the 0009 permissive policy; replaced with `mark_conversation_read(p_conversation_id)` (in `0013`) that checks membership and updates in one shot. Removes any RLS ambiguity; the WAL change still reaches Realtime so the sender's tick flips live and the reader's unread badge drops.

**Notifications edge function was broken.** `notify-new-message/index.ts` referenced `subs` in the send loop but **never queried `push_subscriptions`** — the function threw at runtime, so it could never deploy (which is why the *old* generic "from Albine" version was still live). Added the `push_subscriptions` fetch by `recipientIds`. Title already carries the sender/group name.

**User must do (server side — I can't):**
1. Apply migration `supabase/migrations/0013_prekey_repair_and_read_rpc.sql` in the SQL editor.
2. Redeploy the edge function: `supabase functions deploy notify-new-message`.
3. Let GitHub Pages rebuild (push triggers CI), then **hard-reload on the phone** (or clear site data) so it drops the stale cached service worker and runs the new client. Both devices on the new build → chats self-heal within a message or two.
4. Per device, stick to **one** URL (don't mix `localhost` and `127.0.0.1`).

---

## 2026-07-26 — live-testing fixes: session hang, UX polish, push metadata

**Status:** Round of fixes from a real two-account cross-device test. All build clean (`flutter analyze`, `flutter build web --pwa-strategy=none`). The core E2E decrypt failure the user hit is diagnosed but **not a code bug** (see below).

**Cross-device decrypt failures ("Не удалось расшифровать" both directions) — diagnosed, root cause is test-environment key desync, not a bug.** The added logging (previous commit) revealed the exact errors: `InvalidKeyIdException - No such prekey: 1,2,3…10` (Signal path) and `SodiumException` (crypto_box path), all from the *same* peer. Prekey ids 1–10 all missing means the sender keeps establishing a *fresh* X3DH session every message instead of reusing an existing one — which happens when the two sides' key material genuinely doesn't match what's published server-side. Almost certainly because the same account was tested across *two different origins* (the deployed GitHub Pages site **and** the local `localhost:5050` dev server), each of which has its own separate `shared_preferences`/Signal local store, so each origin generated its own identity+prekeys and overwrote the other's `profiles.identity_pubkey` server-side. Nothing in the code is wrong here; the fix is operational — pick *one* origin per device and, if already desynced, use the profile screen's "Сбросить ключ шифрования" (rotate) once on each side, or clear site data and re-login. Documented so it isn't mistaken for a live bug next time.

**Real bug fixed — endless chat-list spinner after a reload on a network blip.** `SessionController._refresh()` awaited `unlock()`/`fetchProfile()` etc. with no surrounding try/catch, so a transient `ERR_CONNECTION_RESET` (which the user hit) threw uncaught and left `state` stuck at `SessionStatus.loading` forever — the router shows a bare spinner in that state. Wrapped `_refresh` in try/catch with a 3-second retry, and specifically guarded `fetchBackup()` inside `unlock()` so a network failure there returns a clean "проверь соединение" error instead of falling through to fresh-keygen (which would silently orphan the account's identity on a mere network hiccup).

**UX fixes this round:**
- **Enter sends / Shift+Enter = newline** on a physical keyboard (desktop/web): the composer `TextField` is now wrapped in a `Focus` with an `onKeyEvent` that swallows a bare Enter (calls `_send`) and lets Shift+Enter fall through to the default newline. `TextField.onSubmitted` alone only fires for the on-screen keyboard, so this was the missing desktop path.
- **Desktop right-click no longer stacks the browser's native context menu** on top of our own action sheet — `BrowserContextMenu.disableContextMenu()` in `main()`.
- **Unread message count badge** in the conversation list — `ConversationSummary.unreadCount` computed in `fetchConversations()` from the already-fetched rows (`read_at == null && sender != me`), rendered as an accent pill (grey when the chat is muted).
- **Fixed the stray pink/purple tint** on some buttons — `buildAlbineTheme()` was calling `.copyWith(primary: ...)` on `ThemeData.light()`'s *un-seeded* Material 3 palette, leaving every un-overridden role (incl. press/hover state-layer overlays) on Flutter's default purple hue. Now derives the whole `ColorScheme` from the app's own accent via `ColorScheme.fromSeed`.
- **"Новый чат" picker** ("Личное сообщение"/"Групповой чат") redesigned as a centered, dimmed dialog with a title and `AppCard` rows (new `center` option on `showBlurredModalSheet`) instead of a cramped bottom-anchored dropdown.
- **Group avatar can now be set at creation time** — `new_group_sheet.dart` gained an avatar picker (reuses `pick_image.dart`), uploaded best-effort right after `startGroupConversation`.
- **Camera glyph is now a true square** (was `height: size*0.86`, slightly flattened).

**Push notifications — now show the sender/group name (safe metadata, still no message text).** `notify-new-message` edge function now looks up the sender's `display_name` and, for groups, the conversation `title`, and uses `"Женя"` / `"Женя • Группа"` as the notification title (body stays the generic "Новое сообщение"). This is public metadata the server already knows, not message content — it never touches ciphertext, so E2E is intact. **User needs to redeploy the edge function** for this to take effect (code-only change, no new secret).

**Still open / needs the user:**
- Read receipts not flipping to double-check: the user read on the 2nd account but the 1st still shows one grey check. This depends on `markMessagesRead` actually writing `read_at` — needs checking that `0009_read_receipts.sql` is applied and its RLS policy lets the reader update. To verify next round (couldn't reproduce without two live sessions).
- Redeploy `notify-new-message` (for the sender-name title).

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

---

## 2026-07-17 — M3: media attachments (photo/video/file)

**Status:** User asked to resume M3 (paused earlier for the UI overhaul). Implemented: pick + send photo/video/file from the paperclip icon, encrypted end-to-end, uploaded to a new private Storage bucket, decrypted and rendered on receipt. `flutter analyze` clean, `flutter build web` succeeds. Not yet tested live.

**Encryption design:** reuses the *exact same* generic AEAD primitives already built for group text messages (`CryptoService.generateGroupKey`/`encryptGroupMessage`/`decryptGroupMessage` — nothing about them is actually group-specific, just named that way) — a fresh random symmetric key per file, sealed (`crypto_box_seal`) to every conversation member's identity public key **including the sender's own**, same reason group message keys are sealed to self too (so the sender can reopen their own sent media after a reload). This means media inherits the same accepted trade-off groups already have: no forward secrecy (a compromised identity key could retroactively decrypt past media, same as it already could for group text) — not a new gap, just extending the existing one.

**New migration:** `supabase/migrations/0008_media_storage.sql` — creates the `media` Storage bucket (private) and two RLS policies on `storage.objects` (select/insert) that authorize purely from the object path (`<conversation_id>/<uuid>`) via the existing `is_conversation_member()` helper, no new lookup table needed. **Requires applying to the live Supabase project — not done yet.**

**Changed files:**
- `pubspec.yaml` — added `file_picker` (cross-platform file selection, works on web via in-memory bytes) and promoted the already-transitive `uuid` to a direct dependency (used to name storage objects).
- `lib/domain/models.dart` — `ChatMessage` gains `mediaObjectPath`/`mediaWrappedKey`/`mediaNonce`/`mediaSizeBytes`/`mediaMimeHint` (+ `isMedia` getter) reading the columns that already existed in the schema since `0001_init.sql` but were unused until now.
- `lib/data/chat_repository.dart` — new `sendMediaMessage()` (encrypt, upload via `storage.from('media').uploadBinary`, seal the key per recipient, insert the message row) and `fetchAndDecryptMedia()` (download + open the sealed key + AEAD-decrypt, cached per message id since each file has its own unique key unlike the shared per-conversation group text key). `decryptText()` now returns a short label ("📷 Фото"/"🎥 Видео"/"📎 Файл") for media messages instead of trying to decrypt them as text — used by reply-quote previews, the pinned banner, and the chat-list preview.
- `lib/features/chat/chat_screen.dart` — paperclip icon now opens an attachment sheet (Фото/Видео/Файл, reusing `showBlurredModalSheet`/`ActionSheetTile`); `_pickAndSendMedia` drives `file_picker` and calls `sendMediaMessage` with the right recipient list (self + peer, or self + all group members); message bubbles branch on `content_type`: images render inline via `Image.memory` (with a loading spinner while `fetchAndDecryptMedia` runs), files/videos render as a chip (icon + size) that decrypts and triggers a browser download via `dart:html`'s Blob/AnchorElement trick on tap — the standard way to save in-memory bytes to disk from Flutter Web, which has no filesystem access. Video keeps `content_type: 'file'` (no inline player yet) with a `video/*` `media_mime_hint` for a future client to use instead of adding a third content_type now.

**Next steps:**
1. Apply `0008_media_storage.sql` to the live Supabase project (along with the still-outstanding `0005`/`0006`/`0007`).
2. Manual E2E: send a photo/video/file in both a direct and a group chat, confirm the image renders inline, confirm downloading a file/video produces a working local file, confirm existing text messages are unaffected.

**Follow-up — confirmed working, but photo/video needed a real viewer.** User applied `0008` and media started sending, but reported photos/videos were rendered exactly like a text message (stuck in the same padded, colored chat bubble) instead of opening as their own thing — every other messenger opens a tap target with a dedicated viewer (close + download), not an inline-forever thumbnail. Files were fine as-is (a chip that downloads directly).
- Added `video_player` (pulls in `video_player_web` automatically) and a new `_MediaViewerDialog` — a full-screen black backdrop with the photo pinch-zoomable (`InteractiveViewer`) or the video playing (via a `Blob` URL fed to `VideoPlayerController.networkUrl`, tap to pause/resume), a close (✕) button and a download button, both top corners. Tapping an image thumbnail or a video chip opens this; tapping a generic file still downloads immediately (no viewer makes sense for an arbitrary file type) — matches what was explicitly asked for.
- Restyled the image bubble itself: no more colored background/padding around it (`isImage` branch: `padding: EdgeInsets.zero`, `color: Colors.transparent`) — the photo now fills the rounded shape edge-to-edge, with the timestamp as a small dark overlay badge on the image's corner instead of separate text on a colored strip below it.

**Next steps:**
1. Manual E2E: tap a sent/received photo → viewer opens, pinch-zoom works, download works, close returns to the chat; same for a video chip (playback, not just the poster frame); confirm a generic file still just downloads on tap.

---

## 2026-07-17 (later) — attachment picker simplified, camera glyph redrawn, multi-pin cycling

**Attachment picker:** the custom Фото/Видео/Файл sheet was redundant — the OS file dialog it opened afterward already lets you filter/browse, so picking twice was pure friction. Paperclip now calls `FilePicker.pickFiles()` directly (one native dialog, no app-side menu); `content_type`/mime are inferred from the picked file's extension instead of from which menu option was tapped. `_showAttachmentMenu` removed.

**Camera glyph:** `CupertinoIcons.camera` still didn't read clearly as "rounded square with a circle lens" at composer icon size. Replaced with a small hand-drawn `_CameraGlyph` widget (two nested `Container`s — a rounded-rect border + a circle border centered inside) so the shape is exact and font-independent, matching Telegram's icon precisely. Paperclip also got a small circular tap-target background (`Material`/`InkWell` in a `CircleBorder`) to match the visual weight of the send button and camera glyph — user found the plain `IconButton` version "insufficiently rounded."

**Multi-pin cycling:** `toggle_message_pin` always supported pinning more than one message, but the banner only ever showed the single latest one with no way to reach the others. `ChatRepository.fetchPinnedMessage()` (singular) replaced with `fetchPinnedMessages()` (plural, oldest-first); `chat_screen.dart` tracks `_pinnedIndex` and cycles backwards through older pins on repeated taps of the banner (wrapping back to the newest after the oldest), showing an "N/M" counter when there's more than one — same interaction as Telegram's pinned-message bar.

**Bug: deleted messages stuck around until leaving and re-entering the chat.** `deleteMessage()` hard-deletes the row, but the UI only finds out via `messagesStreamProvider`'s realtime subscription round-tripping back — if that lags (or a background/reconnecting tab misses the event), the message just sits there until something re-triggers a fresh fetch, which re-entering the chat does. Fixed with an optimistic-UI set: `_locallyDeletedIds` is updated the instant a delete is initiated (both the single-message action and multi-select), and `_buildListEntries` skips anything in it immediately — independent of whether/when the realtime DELETE event actually shows up. The set is never cleared; once the row is truly gone server-side it just also stops appearing in `items`, so a stale id sitting in the set forever is harmless.

**Next steps:**
1. Manual E2E: paperclip opens the OS dialog directly (photo/video/doc all still send correctly via extension-based detection), camera glyph renders as a clean rounded-square-with-circle, pinning 2+ messages and tapping the banner repeatedly cycles through all of them and wraps around.

**Follow-up — downloaded media had no proper filename; viewer's download button was hard to find.**
- **Bug:** `_downloadMedia`'s `<a download="...">` attribute was hardcoded to the bare string `"video"` or `"file"` — no extension at all, so the browser saved every photo/video/document as a nameless, extension-less blob the OS had nothing to associate a preview/app with (this is what read as "saved as generic files"). Added `_extensionForMime()` and now download as e.g. `photo.jpg`/`video.mp4`/`file.pdf`.
- **Viewer redesign:** the download button was a small icon tucked in a corner, easy to miss. Replaced the top-left/top-right icon pair with a minimal close (✕) top-left and a full-width, clearly labeled "Скачать" bar pinned to the bottom of the screen (semi-transparent black, icon + text) — matches Telegram's photo/video viewer action bar instead of a corner icon.

---

## 2026-07-22 — real video player, robust menu positioning, read receipts

**Status:** User rejected the bottom "Скачать" bar viewer as still not good enough, referencing real Telegram screenshots (a proper full-screen video player with scrubbing/skip/duration, not a static frame with a download bar) and separately reported the long-press action menu still sometimes rendering off-screen, plus asked for delivery/read receipts (single/double check, own design). Did everything that could be done and verified without live Supabase/browser access; explicitly left live E2E for the user, per their request ("что не можешь протестировать оставь, я сам сделаю"). `flutter analyze` clean (only pre-existing style infos), `flutter build web` succeeds.

**1. Real video player in `_MediaViewerDialog` (`lib/features/chat/chat_screen.dart`).** Replaced the "static frame + bottom Скачать bar" with actual Telegram-style transport controls, built on top of the existing `video_player` package (no new dependency):
- `VideoProgressIndicator(controller, allowScrubbing: true)` — a real scrubbable seek bar (built into `video_player`, no need to hand-roll one), with current-position/duration labels underneath.
- Center play/pause toggle, flanked by ±15s skip buttons (`CupertinoIcons.gobackward_15`/`goforward_15`), matching the reference screenshot's layout exactly.
- Controls auto-hide 3s after playback starts and reappear on tap (`_resetHideTimer`/`AnimatedOpacity`/`IgnorePointer` when hidden) — same behavior as every native video player, so the video isn't permanently covered by an overlay.
- Download moved to a small icon button in a slim top bar (next to close), freeing the bottom of the screen for the transport controls. Photo viewer unchanged (pinch-zoom via `InteractiveViewer`), just shares the same top bar now.

**2. Fixed the anchored action-menu going off-screen (`lib/shared/widgets/app_widgets.dart`).** The previous fix (`showBlurredModalSheet`'s `anchorRect` support) positioned the card with a bare `Positioned(top/bottom)` based on a guessed 320px height — a wrong guess (short menu, long message preview, keyboard eating vertical space) could place it partly or fully off-screen with nothing pulling it back. Replaced with `CustomSingleChildLayout` + a new `_AnchoredSheetLayoutDelegate`: the delegate receives the card's *actual measured size* before positioning it, decides above-vs-below from that real size (not a guess), and clamps the final position to `[safeTop, screenHeight - safeBottom]` / `[gap, screenWidth - gap]` — accounting for the keyboard inset too. The card physically cannot end up off-screen now, regardless of content size or anchor position.

**3. Read/delivery receipts — single check (sent) / double check (read), own design.** New `supabase/migrations/0009_read_receipts.sql`: `messages.read_at timestamptz` + a new permissive UPDATE policy letting a non-sender conversation member set it (the existing UPDATE policy was sender-only, for edit/soft-delete — Postgres OR's multiple permissive policies together, so this adds to it rather than replacing it). **Not yet applied to the live Supabase project — needs to be run there before this feature works.**
- Deliberate scope: one `read_at` per message, set the first time *any* other member reads it — correct semantics for direct chats (only one other member); for groups this reads as "read by at least one person," not a full per-member matrix (that would need a join table and isn't worth it without a group read-receipt UI planned). Documented inline in the migration.
- `ChatRepository.markMessagesRead(conversationId)` — bulk-updates every unread message from other senders to `read_at = now()`; called from `chat_screen.dart` (`_maybeMarkRead`, post-frame, deduped via a local `_markReadRequested` set so the same batch isn't re-sent every rebuild) whenever the message list renders with unread messages in it.
- `ChatMessage.readAt` (parsed in `fromRow`) + a new `_statusTicks()` helper in `chat_screen.dart`: `Icons.done` (single check, dimmed) when unread, `Icons.done_all` tinted a WhatsApp-style light blue when `readAt != null`, shown next to the timestamp on my own messages only (both the plain-text/file bubble and the photo's dark time-overlay badge). Propagates to the sender in near-real-time via the existing `messagesStreamProvider` realtime stream, which already reacts to UPDATE events — no new subscription needed.

**Next steps:**
1. Apply `0009_read_receipts.sql` to the live Supabase project (still outstanding, same as earlier un-applied migrations if any remain).
2. Manual E2E (user is doing this): video plays with working scrub/skip/play-pause and auto-hiding controls; long-press menu near screen edges (top, bottom, with keyboard open) stays fully on-screen; sending a message shows a single check, and it flips to a blue double-check once the recipient opens the chat.

**Follow-up — user reported the viewer was still broken ("video plays but controls aren't right", "photo opens crooked").** This environment's Browser-pane tooling still can't drive this app's canvaskit build (screenshot hangs, confirmed by trying again), so asked the user to describe the actual symptom rather than re-guessing blind, then found and fixed two real bugs from that description:
- **Photo bug (root cause of "crooked"):** `Image.memory` inside `InteractiveViewer` inside `Center` had no bounded size anywhere in that chain — `Center` gives loose/unbounded constraints and `InteractiveViewer` doesn't constrain its child either, so `BoxFit.contain` had nothing to fit *into* and the photo rendered at its native pixel size (often several thousand px on a phone photo) instead of scaled to the screen — a huge image cropped to whatever corner happened to land in the viewport. Fixed with a `LayoutBuilder` feeding an explicit `SizedBox(width/height: constraints.max...)` around the `Image.memory`.
- **Video controls bug:** the skip/play-pause row and progress bar were nested inside the same `Stack` as the `AspectRatio`-sized video box, so they were constrained to the video's own width — for a narrow/portrait video this could clip or overflow the transport controls instead of spanning the device width like the Telegram reference. Moved `_videoControls` out to its own full-screen `Positioned.fill` sibling (same level as the top bar) instead of nested inside the video's own box; the dim tap-to-toggle background now also spans the full screen and stays wired to the same play/pause toggle.
- Also (proactively, before this specific feedback): guarded against a zero/NaN video aspect ratio (some browsers report it briefly while metadata loads) collapsing the video into an invisible zero-size box in release builds, and silenced the console-level unhandled rejection when browser autoplay policy blocks `play()` after an async gap.
- Still not independently verified live (same tooling limitation) — asking the user to re-check both after this round.

**Follow-up — user sent Telegram reference screenshots and said the previous round still wasn't it: bare X + tiny save icon instead of a real nav bar, controls that vanish and never come back on tap, seek bar not draggable, icons "ugly and invisible" with no backing.** Full redesign of `_MediaViewerDialog` in `chat_screen.dart` against the actual references this time:
- **Top bar** now mirrors a real chat header: back chevron (left), conversation title centered, a "..." menu (right) opening the same `showBlurredModalSheet`/`ActionSheetTile` action list as the message long-press menu (Ответить/Сохранить/Переслать/Удалить-if-mine) — not a bare X and a lone download icon.
- **Bottom action bar** (photo only — video's bottom is the transport controls instead): enlarged circular versions of the same forward/save/delete icons from the message action menu, reachable directly without opening "...".
- **All icons now sit on a solid translucent-black circle** (`_circleIconButton`), not bare white glyphs with nothing behind them — this was the literal "ugly, can't see them" complaint. No blur/glassmorphism (user explicitly said a plain version was fine), just a filled circle backing.
- **Real bug found and fixed — controls going permanently invisible:** the tap-to-reveal `GestureDetector` only covered the video's own `AspectRatio` box; for any video narrower/shorter than the full screen (i.e. most videos, letterboxed), the margin beside/above/below the video had *no* widget capturing taps once `IgnorePointer` hid the controls layer — tapping there (very likely where a user's thumb naturally lands) did nothing, reading as "buttons disappear and never come back." Fixed by wrapping the *entire* media area in one `HitTestBehavior.opaque` `GestureDetector` spanning the full screen.
- **Real bug found and fixed — scrubbing felt broken:** the 3-second auto-hide timer had no awareness of an in-progress interaction, so it could fire (and hide + `IgnorePointer`-disable the whole controls layer, `VideoProgressIndicator` included) while a user was still dragging the seek bar. Added a `Listener` around the controls that cancels the hide timer on pointer-down and only restarts it on pointer-up.
- `flutter analyze` clean, `flutter build web` succeeds. Still can't verify visually in this environment (confirmed again — screenshot hangs on this app's canvaskit build); asked the user to re-check.

**Follow-up — user said the video viewer's chrome didn't match the photo viewer, the bottom "Сохранить" button on the photo was never asked for (it's already in "..."), and the progress bar still looked like a generic default widget.**
- Removed "Сохранить" from `_bottomActionBar()` — it was redundant with the "..." menu, which the user pointed out directly. Bottom bar is now just Переслать + Удалить (if mine).
- That same bottom bar is now shared by *both* photo and video (previously video had no bottom bar at all) — embedded inside the video controls' fading/hiding section so it shows and hides together with the rest of the transport controls, rather than being a separate always-on bar.
- Replaced the stock `VideoProgressIndicator` (a thin, library-default-styled line the user explicitly disliked — "я хочу своё") with a hand-rolled `_VideoScrubBar`: a thicker rounded track in the app's own accent color, a draggable thumb that grows slightly while dragging, tap-to-seek and drag-to-scrub both implemented directly via `GestureDetector` rather than the built-in widget's gesture handling.
- `flutter analyze` clean, `flutter build web` succeeds. Not yet re-verified live by the user.

**Follow-up — user sent Telegram *desktop* reference screenshots and more mobile-viewer polish requests.**
- **Desktop message actions now also open via right-click** (`onSecondaryTapDown` on the message bubble, anchored at the exact click point) — long-press is a touch-only gesture with no mouse equivalent, so this was previously unreachable with a mouse at all except by the composer's copy affordance.
- **Forward-to picker redesigned for desktop**: `showBlurredModalSheet` gained `alwaysDim`/`centerOnWide` options — the small anchored message-action menu still stays undimmed on desktop per the original Telegram-desktop-reference design, but a full modal like the forward picker now always dims the backdrop and centers itself on wide screens instead of pinning to the bottom (which only ever made sense as a mobile bottom-sheet convention). `_ForwardPickerSheet` itself gained a search field (client-side filter by title) and an explicit "Отмена" button, plus a "N участников" subtitle for group rows — closer to the actual Telegram dialog referenced.
- **Mobile viewer polish:** bottom action bar now uses `spaceBetween` + horizontal padding to push Переслать/Удалить toward the screen edges instead of clustering center; the top-bar title sits in a rounded translucent pill (`Container` + `BorderRadius.circular(16)`) instead of bare floating text, matching the same "everything has a backing" language as the circular icon buttons.
- **Native OS save/share sheet on download:** `_downloadMedia` now tries the Web Share API's file-sharing capability first (`navigator.canShare`/`navigator.share` with a real `File`, via `package:web` + `dart:js_interop` — added `web: ^1.1.1` as a direct dependency) so iOS/Android show their own native "Save Image"/share sheet instead of a silent, unprompted download; falls back to the classic Blob+`<a download>` trick when the browser doesn't support file sharing at all (typically desktop, where a plain download is already the expected/correct behavior — no complaint was raised about that case). Note: `dart:js_util` doesn't resolve in this SDK/toolchain (Dart 3.12.2) — `package:web`'s typed bindings (`web.File`, `web.ShareData`, `Uint8List.toJS`, `JSPromise.toDart`) were used instead, which is also the currently-recommended approach over the older js_util/js interop.
- **Explicitly not done — a separate desktop-specific minimal viewer layout** (matching the second reference screenshot: small caption bottom-left showing "Photo N of M" + sender + date, tiny icon row instead of the big circular buttons). That reference implies gallery paging across every media item in a conversation, which doesn't exist yet (nothing today lets you page between the previous/next photo in a chat) — a real version of that would need to build that navigation feature first rather than just re-skinning the current single-item viewer. Left alone rather than shipping a half-matching decoy.
- `flutter analyze` clean, `flutter build web` succeeds. Not yet verified live by the user (same environment limitation — this app's canvaskit build still hangs this environment's browser screenshot tool).

---

## 2026-07-25 — contact profile + group management screens

**Status:** New feature (not a bugfix round) — tapping a chat's AppBar title now opens a profile view: for a direct chat, the peer's avatar/name/username + shared media; for a group, a full management screen (rename, member list, add/remove members, shared media). `flutter analyze` clean, `flutter build web` succeeds. Not yet tested live.

**Schema:** `supabase/migrations/0010_group_management.sql` — a single new policy, `"owner/admin can rename conversation"` (UPDATE on `conversations`, gated by the existing `is_conversation_admin()` helper). Adding/removing members needed **no new policy or RPC** — the existing `conversation_members` INSERT policy ("owner/admin can add members, or self at creation") already covers adding a member post-creation, and the existing DELETE policy ("owner/admin can remove members") already covers removal; both were already scoped correctly in `0001_init.sql`, just never used from the client until now. **Requires applying `0009`/`0010` to the live Supabase project** if not already done.

**Roles:** scoped exactly to what was asked — only owner-vs-not is surfaced (`GroupMember.isOwner`, new in `models.dart`); the schema's `role in ('owner','admin','member')` already supports a future `'admin'` tier, deliberately not wired into any UI yet ("роли пока не нужны").

**`lib/data/chat_repository.dart` additions:**
- `fetchGroupMembers()` — member list with role, owner sorted first.
- `updateGroupTitle()`, `addGroupMember()` (unseals this device's own group key via the existing `_tryGroupKeyFor`, reseals it for the new member — same key, not a fresh one, so existing messages stay readable), `removeGroupMember()`.
- `fetchMediaMessages()` — every photo/video/file ever sent in a conversation, newest first (powers the new shared-media grid).

**New files:**
- `lib/core/media_download.dart` — extracted `chat_screen.dart`'s native-share/download logic (added last round) into a standalone, reusable module (`saveMediaBytes`/`suggestedMediaFilename`/`extensionForMime`) since the new gallery grid needed the exact same download behavior; `chat_screen.dart` now calls this instead of duplicating it.
- `lib/features/profile/media_gallery_grid.dart` — shared-media grid (3-column, newest first) used by both new screens; tapping a photo opens a minimal pinch-zoom viewer, video/file thumbnails download directly. Deliberately doesn't reuse the chat's full reply/forward/delete viewer chrome — those actions don't map cleanly onto "browse everything ever shared."
- `lib/features/profile/contact_profile_screen.dart` — direct-chat peer profile: avatar, display name, `@username`, shared media.
- `lib/features/profile/group_info_screen.dart` — group management: tap-to-rename title (owner only, small edit-pencil affordance), member list with a "Создатель" badge on the owner and a remove button (owner only, never on self), "Добавить" opening a search+multi-select sheet (`_AddMembersSheet`, a trimmed variant of `new_group_sheet.dart`'s search UI — some duplication between the two accepted rather than forcing a shared abstraction across two already-different flows), shared media.
- `lib/features/chat/chat_screen.dart` — AppBar title wrapped in an `InkWell`; `_openProfileOrGroupInfo()` pushes the right screen based on `conversation.kind`.

**Next steps:**
1. Apply `0010_group_management.sql` to the live Supabase project (along with `0009` if not already done).
2. Manual E2E: open a direct chat's profile (avatar/name/username/media all correct); open a group's info screen as owner (rename works, add/remove member works, media shows) and as a non-owner (rename/add/remove controls are hidden, everything else still visible).

---

## 2026-07-25 (later) — avatars, member profile view, and M4 push notifications

**Status:** User asked for all three in one go, then stepped away — "write the code, do everything, I'll come back and handle the tokens/secrets myself." Implemented everything that doesn't require live secrets; push notifications are code-complete but genuinely cannot be tested end-to-end without the user generating a VAPID keypair, deploying the edge function, and wiring the DB trigger — none of which this environment has credentials/CLI access for (same constraint as every other migration in this project). `flutter analyze` clean, `flutter build web --pwa-strategy=none` succeeds.

**Avatars (profile + group):**
- New public `avatars` Storage bucket (`0011_avatars.sql`) — unlike the private `media` bucket, avatars aren't secret content, so they're served as plain public URLs (no signed URLs, no client-side decryption). Fresh object path per upload (`profile/<id>/<uuid>.<ext>` / `group/<id>/<uuid>.<ext>`) rather than overwriting in place — simpler than getting upsert semantics right, at the cost of orphaning the previous file in storage (accepted trade-off, not worth a cleanup job at this scale).
- `conversations.avatar_url` reuses the owner/admin UPDATE policy from `0010` — no new policy needed.
- `ProfileRepository.uploadAvatar()` / `ChatRepository.uploadGroupAvatar()`; `SessionController.updateProfile()` (new) refreshes the in-memory cached profile immediately after a personal-avatar upload so it shows everywhere without a reload.
- Wired into `ProfileScreen` (tap own avatar) and `GroupInfoScreen` (tap group avatar, owner-only) with a small camera-badge affordance; real avatar images now render (via `NetworkImage`) in both places plus the conversations list and contact profile, instead of always falling back to initials.
- New shared `lib/core/pick_image.dart` (`file_picker`, image-only) used by both upload flows.

**Member profile view:** `GroupInfoScreen`'s member rows are now tappable, opening `ContactProfileScreen` for that member. `ContactProfileScreen.conversationId` is now nullable — there's no 1:1 conversation to pull shared media from when opened this way, so that section is just omitted rather than faked.

**Push notifications (M4) — code-complete, needs the user's secrets to actually go live:**
- **Client** (`lib/data/push_repository.dart`): requests `Notification` permission, subscribes via the browser's `PushManager` (VAPID `applicationServerKey`, urlsafe-base64 → bytes), upserts the subscription (endpoint/p256dh/auth_key) into the existing `push_subscriptions` table (schema already had this since `0001_init.sql`, unused until now). Built on `package:web` + `dart:js_interop` — `dart:js_util` doesn't resolve on this Dart/Flutter toolchain (3.12.2 / 3.44.4), confirmed the same finding as the earlier native-share work.
- **Service worker** (`web/push_sw.js`): handles `push` (always shows a generic "Новое сообщение" — see the E2E note below) and `notificationclick` (focuses an existing tab or opens a new one). Flutter's own generated service worker is now built with `--pwa-strategy=none` (`.github/workflows/deploy.yml` updated) since it only does asset pre-caching, has no push support, and a scope can only ever have one active controller anyway — registering `push_sw.js` (from `web/index.html`) would have silently replaced it either way. Confirmed locally: the generated `flutter_bootstrap.js` now calls `_flutter.loader.load()` with no `serviceWorkerSettings` at all.
- **UI**: a "Push-уведомления о новых сообщениях" toggle in `ProfileScreen`, hidden entirely when `PushRepository.isSupported` is false (no Push API at all — e.g. Safari on iOS unless this PWA is added to the Home Screen).
- **Server** (`supabase/functions/notify-new-message/index.ts`, Deno, `npm:web-push`): on each new message, looks up every *other* conversation member's subscriptions and sends `{title, body: "Новое сообщение", url}` to each, deleting any subscription the push service reports as gone (404/410). **Strict E2E, not a placeholder**: the function only ever sees the ciphertext row — it has no plaintext to put in the notification even if it wanted to, so the generic body is the deliberate, permanent answer to the "развилка" ROADMAP.md flagged for this milestone.
- **Trigger** (`supabase/migrations/0012_push_notifications.sql`): a `pg_net`-based `AFTER INSERT` trigger on `messages` calling the edge function. The URL and service-role key can't be committed to git, so the trigger reads them from **Supabase Vault** (`vault.decrypted_secrets`) — a harmless no-op until those two secrets exist (see checklist below). Originally tried `current_setting('app.settings.*')` + `ALTER DATABASE ... SET`, but the SQL editor's role isn't allowed to set arbitrary database-level GUCs on a hosted project ("permission denied to set parameter") — Vault is Supabase's actual supported mechanism for exactly this "give a trigger function a secret" case.

**Actually done together with the user this round:**
1. Generated a VAPID keypair locally via OpenSSL (no Node/npx available in this environment or the user's machine — `web-push generate-vapid-keys` needs Node) — raw P-256 EC keypair, manually converted to the same base64url raw-bytes format `web-push` would produce.
2. Public key written to the user's local `.env` as `VAPID_PUBLIC_KEY`.
3. Public key pushed to the `VAPID_PUBLIC_KEY` GitHub Actions secret via `gh secret set` (confirmed with the user first).
4. Private key handed to the user directly in chat for pasting into the edge function's own secrets (never committed anywhere).

**Still needs the user** (none of it possible from this environment):
1. Deploy `supabase/functions/notify-new-message/index.ts` — via the Dashboard's Edge Functions UI (paste the code directly; no CLI installed), or `supabase functions deploy notify-new-message` if they set up the CLI.
2. Set that function's secrets: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT=mailto:...`.
3. Apply `0011_avatars.sql` and `0012_push_notifications.sql` to the live project (along with `0009`/`0010` if not already done).
4. In the SQL editor, run the two `vault.create_secret(...)` calls from `0012`'s comment (own project URL + service_role key) — no session restart needed, unlike the old `ALTER DATABASE` approach.

**Next steps:**
1. The six-step checklist above (all needs real secrets/CLI access this environment doesn't have).
2. Manual E2E once configured: toggle notifications on in `ProfileScreen`, send a message from a second account, confirm a system notification appears and clicking it focuses/opens the app; confirm avatar upload/display and the group-member profile-view work as described above (these three *can* be tested without any push setup).
