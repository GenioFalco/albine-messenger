import 'dart:convert';
import 'dart:typed_data';

import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../services/crypto/crypto_models.dart';
import '../services/crypto/crypto_service.dart';
import '../services/crypto/key_storage.dart';
import '../services/signal/signal_service.dart';

/// All chat data access + the encrypt/decrypt boundary. UI code never touches
/// ciphertext or the Supabase client directly — it goes through here.
///
/// Direct (1:1) messages use either the legacy `crypto_box` or the
/// forward-secret Signal path (see M1.5 in ROADMAP.md). Group messages (M2)
/// use a third scheme: one shared symmetric key per group, sealed per
/// member via `crypto_box_seal` — no forward secrecy for groups yet, by
/// design (see ROADMAP.md "Приняты сознательно").
class ChatRepository {
  ChatRepository({
    required SupabaseClient client,
    required CryptoService crypto,
    required IdentityKeyPair myKeyPair,
    required String myUserId,
    required SignalService signal,
    required KeyStorage keyStorage,
  }) : _client = client,
       _crypto = crypto,
       _myKeyPair = myKeyPair,
       _myUserId = myUserId,
       _signal = signal,
       _keyStorage = keyStorage;

  final SupabaseClient _client;
  final CryptoService _crypto;
  final IdentityKeyPair _myKeyPair;
  final String _myUserId;
  final SignalService _signal;
  final KeyStorage _keyStorage;

  /// Identity keys retired by a past "rotate my key" action (see
  /// `SessionController.rotateIdentityKey`), tried in order when the
  /// *current* key fails to decrypt a `protocol: 'crypto_box'` message —
  /// this is what keeps old messages readable after a rotation. Loaded once
  /// and cached; see [_ensureRetiredKeysLoaded].
  List<Uint8List>? _retiredKeysCache;

  Future<void> _ensureRetiredKeysLoaded() async {
    _retiredKeysCache ??= await _keyStorage.loadRetiredSecretKeys(_myUserId);
  }

  /// Plaintext of messages *this device* sent via the forward-secret Signal
  /// path, keyed by message id. Needed because — unlike the legacy
  /// crypto_box's symmetric shared secret — a Double Ratchet session
  /// cannot decrypt its own outgoing ciphertext by design (each message key
  /// is deleted right after use; that's what forward secrecy *is*). Real
  /// Signal clients solve this by never trying to re-decrypt their own sent
  /// messages at all — they already have the plaintext locally (the sender
  /// typed it) and keep it in a local message store instead.
  ///
  /// This app has no general local message store, so this is a narrow,
  /// purpose-built equivalent: persisted to `shared_preferences` (loaded via
  /// [_ensureEchoLoaded], written via [_rememberSentEcho]), capped to the
  /// most recent [_maxSentEchoEntries] so it can't grow unbounded on a
  /// device used for years. Per-device, same as every other local key
  /// material in this app — sending the same message from a second device
  /// still won't show it there, since that device never had the plaintext.
  final Map<String, String> _sentSignalEcho = {};

  Future<void>? _echoLoaded;
  static const _maxSentEchoEntries = 500;
  String get _sentEchoPrefsKey => 'albine.sent_echo.$_myUserId';

  Future<void> _ensureEchoLoaded() {
    return _echoLoaded ??= () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sentEchoPrefsKey);
      if (raw == null) return;
      final stored = jsonDecode(raw) as Map<String, dynamic>;
      _sentSignalEcho.addAll(stored.map((k, v) => MapEntry(k, v as String)));
    }();
  }

  Future<void> _rememberSentEcho(String messageId, String plaintext) async {
    await _ensureEchoLoaded();
    _sentSignalEcho[messageId] = plaintext;
    while (_sentSignalEcho.length > _maxSentEchoEntries) {
      _sentSignalEcho.remove(_sentSignalEcho.keys.first);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sentEchoPrefsKey, jsonEncode(_sentSignalEcho));
  }

  /// Resolved plaintext for incoming (not-mine) `protocol: 'signal'`
  /// messages, populated by [_prewarmSignalDecryption] before a message
  /// list is ever handed to the UI — decryption is inherently async
  /// (session-store lookups), but [decryptText] itself must stay
  /// synchronous since it's called straight from `ListView.builder`'s
  /// `itemBuilder`. See [watchMessages] and [fetchConversations].
  final Map<String, String> _signalDecryptCache = {};

  /// Decrypts any not-yet-cached `protocol: 'signal'` messages in
  /// [messages] and stashes the result in [_signalDecryptCache], so
  /// [decryptText] can read it back synchronously afterwards.
  Future<void> _prewarmSignalDecryption(Iterable<ChatMessage> messages) async {
    await _ensureEchoLoaded();
    await _ensureRetiredKeysLoaded();
    for (final m in messages) {
      if (m.protocol != 'signal') continue;
      if (_sentSignalEcho.containsKey(m.id) ||
          _signalDecryptCache.containsKey(m.id))
        continue;

      if (m.senderId == _myUserId) {
        // My own message, and not in the persisted echo cache — sent from a
        // different device, or from before this cache existed. A Double
        // Ratchet session can't decrypt its own outgoing ciphertext (see
        // _sentSignalEcho's doc comment above); nothing worth attempting.
        _signalDecryptCache[m.id] = '🔒 Не удалось расшифровать';
        continue;
      }

      final messageType = m.signalMessageType;
      if (messageType == null) {
        _signalDecryptCache[m.id] = '🔒 Не удалось расшифровать';
        continue;
      }

      try {
        final plaintext = await _signal.decryptFromContact(
          m.senderId,
          m.ciphertext,
          messageType,
        );
        _signalDecryptCache[m.id] = utf8.decode(plaintext);
      } catch (_) {
        // Self-heal instead of leaving the conversation permanently broken:
        // drop the local session so the *next* message to/from this contact
        // triggers a fresh X3DH handshake. This message itself stays
        // unrecoverable (correct — that's forward secrecy), but the
        // conversation recovers going forward with no manual action.
        await _signal.resetSessionWith(m.senderId).catchError((_) {});
        _signalDecryptCache[m.id] = '🔒 Не удалось расшифровать';
      }
    }
  }

  /// Latest edit text for a message, keyed by the *original* message's id —
  /// populated by [_applyEditEvents] after the normal prewarm/decrypt passes
  /// have resolved each edit-event row's own plaintext (an edit event is
  /// itself just a normal message under whatever protocol was active, with
  /// `edits_message_id` set; see `0006_conversation_message_actions.sql` for
  /// why an edit can't just overwrite the original ciphertext in place).
  /// [decryptText] checks this before any protocol-specific decryption.
  final Map<String, String> _editOverrides = {};

  /// Resolves every edit-event row in [messages] to its decrypted text and
  /// records it in [_editOverrides], keyed by the message it edits. Must run
  /// after the normal prewarm passes so each edit event's own ciphertext is
  /// already decryptable via the usual [decryptText] path.
  void _applyEditEvents(
    Iterable<ChatMessage> messages, {
    required ConversationKind kind,
    AppProfile? peer,
  }) {
    for (final m in messages) {
      final targetId = m.editsMessageId;
      if (targetId == null) continue;
      final text = decryptText(m, kind: kind, peer: peer);
      if (text.startsWith('🔒'))
        continue; // not resolved yet or failed — leave any earlier override in place
      _editOverrides[targetId] = text;
    }
  }

  /// This device's copy of each group's symmetric key, unsealed once and
  /// cached — group AEAD decryption is otherwise synchronous, so this is the
  /// only async step, same "prewarm before the sync UI read" shape as
  /// [_signalDecryptCache].
  final Map<String, SecureKey> _groupKeyCache = {};

  /// Conversations whose group key failed to fetch/unseal on the most
  /// recent attempt — lets [decryptText] show a permanent failure instead
  /// of the "Расшифровка…" placeholder forever. Cleared automatically as
  /// soon as a later [_prewarmGroupKey] call succeeds (it's a "last attempt
  /// failed" marker, not a permanent give-up — a future retry can still fix
  /// itself, e.g. once the RLS/network hiccup that caused it clears).
  final Set<String> _groupKeyFailed = {};

  /// Fetches + unseals this device's `wrapped_group_key` for [conversationId]
  /// if not already cached. Returns null if there is no such key yet — most
  /// commonly because [conversationId] isn't a group at all (direct
  /// conversations have no `wrapped_group_key` row).
  Future<SecureKey?> _tryGroupKeyFor(String conversationId) async {
    final cached = _groupKeyCache[conversationId];
    if (cached != null) return cached;

    final row = await _client
        .from('conversation_members')
        .select('wrapped_group_key')
        .eq('conversation_id', conversationId)
        .eq('user_id', _myUserId)
        .maybeSingle();
    final wrapped = row?['wrapped_group_key'] as String?;
    if (wrapped == null) return null;

    final key = _crypto.openSealedGroupKey(
      myKeyPair: _myKeyPair,
      sealed: base64Decode(wrapped),
    );
    _groupKeyCache[conversationId] = key;
    return key;
  }

  Future<void> _prewarmGroupKey(String conversationId) async {
    try {
      final key = await _tryGroupKeyFor(conversationId);
      if (key != null) _groupKeyFailed.remove(conversationId);
    } catch (_) {
      _groupKeyFailed.add(conversationId);
    }
  }

  Future<List<ConversationSummary>> fetchConversations() async {
    final memberRows = await _client
        .from('conversation_members')
        .select(
          'conversation_id, pinned_at, muted, hidden_at, conversations!inner(id, kind, title, created_at)',
        )
        .eq('user_id', _myUserId);

    if (memberRows.isEmpty) return [];

    final conversationIds = [
      for (final r in memberRows) r['conversation_id'] as String,
    ];

    final otherMemberRows = await _client
        .from('conversation_members')
        .select('conversation_id, profiles!inner(*)')
        .inFilter('conversation_id', conversationIds)
        .neq('user_id', _myUserId);

    // A direct conversation has exactly one other member; a group has
    // several — group by conversation id rather than collapsing into a
    // single-entry map (which would silently keep only the last row for
    // groups).
    final othersByConversation = <String, List<AppProfile>>{};
    for (final r in otherMemberRows) {
      final cid = r['conversation_id'] as String;
      othersByConversation
          .putIfAbsent(cid, () => [])
          .add(AppProfile.fromRow(r['profiles'] as Map<String, dynamic>));
    }

    final messageRows = await _client
        .from('messages')
        .select()
        .inFilter('conversation_id', conversationIds)
        .order('created_at', ascending: false);

    // Rows are already newest-first, so the first non-edit-event,
    // non-deleted row seen per conversation is the latest real message; the
    // first edit-event row seen is the most recent edit *of any message* in
    // that conversation (only relevant for the preview if it targets that
    // latest message — editing an older message shouldn't resurrect/reorder
    // the preview). Deleted messages are skipped entirely here too — a
    // deleted message being the most recent one shouldn't make the preview
    // show "Сообщение удалено" instead of whatever real message precedes it.
    final lastMessageByConversation = <String, ChatMessage>{};
    final latestEditByConversation = <String, ChatMessage>{};
    for (final row in messageRows) {
      final msg = ChatMessage.fromRow(row);
      if (msg.isEditEvent) {
        latestEditByConversation.putIfAbsent(msg.conversationId, () => msg);
      } else if (msg.deletedAt == null) {
        lastMessageByConversation.putIfAbsent(msg.conversationId, () => msg);
      }
    }

    final summaries = <ConversationSummary>[];
    for (final r in memberRows) {
      final convo = r['conversations'] as Map<String, dynamic>;
      final id = convo['id'] as String;
      final kind = convo['kind'] == 'group'
          ? ConversationKind.group
          : ConversationKind.direct;
      final others = othersByConversation[id] ?? const <AppProfile>[];
      final peer = kind == ConversationKind.direct && others.isNotEmpty
          ? others.first
          : null;
      final members = kind == ConversationKind.group ? others : null;
      final lastMessage = lastMessageByConversation[id];
      final editOfLast = latestEditByConversation[id];
      final editApplies =
          editOfLast != null &&
          lastMessage != null &&
          editOfLast.editsMessageId == lastMessage.id;

      var updatedAt = DateTime.parse(convo['created_at'] as String).toLocal();
      String? preview;
      if (lastMessage != null) {
        updatedAt = lastMessage.createdAt;
        await _prewarmSignalDecryption([
          lastMessage,
          if (editApplies) editOfLast,
        ]);
        await _prewarmGroupKey(id);
        if (editApplies) {
          _applyEditEvents([editOfLast], kind: kind, peer: peer);
          updatedAt = editOfLast.createdAt;
        }
        preview = lastMessage.deletedAt != null
            ? '🗑 Сообщение удалено'
            : decryptText(lastMessage, kind: kind, peer: peer);
      }

      summaries.add(
        ConversationSummary(
          id: id,
          kind: kind,
          updatedAt: updatedAt,
          title: convo['title'] as String?,
          peer: peer,
          members: members,
          previewText: preview,
          pinnedAt: r['pinned_at'] == null
              ? null
              : DateTime.parse(r['pinned_at'] as String).toLocal(),
          muted: r['muted'] as bool? ?? false,
          hiddenAt: r['hidden_at'] == null
              ? null
              : DateTime.parse(r['hidden_at'] as String).toLocal(),
        ),
      );
    }

    final visible = summaries.where((s) => !s.isHidden).toList();
    visible.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return visible;
  }

  Future<void> setConversationPinned(String conversationId, bool pinned) {
    return _client
        .from('conversation_members')
        .update({
          'pinned_at': pinned ? DateTime.now().toUtc().toIso8601String() : null,
        })
        .eq('conversation_id', conversationId)
        .eq('user_id', _myUserId);
  }

  Future<void> setConversationMuted(String conversationId, bool muted) {
    return _client
        .from('conversation_members')
        .update({'muted': muted})
        .eq('conversation_id', conversationId)
        .eq('user_id', _myUserId);
  }

  /// "Deletes" a chat for this account only — hides it from [fetchConversations]
  /// until a newer message arrives (see [ConversationSummary.isHidden]).
  /// Never touches the other member(s)' rows or any message.
  Future<void> hideConversation(String conversationId) {
    return _client
        .from('conversation_members')
        .update({'hidden_at': DateTime.now().toUtc().toIso8601String()})
        .eq('conversation_id', conversationId)
        .eq('user_id', _myUserId);
  }

  /// Re-fetches the conversation list whenever membership or any visible
  /// message changes. Simple "refetch on trigger" rather than a fully
  /// reactive joined view — plenty for a friends-scale app.
  Stream<List<ConversationSummary>> watchConversations() {
    final membershipTrigger = _client
        .from('conversation_members')
        .stream(primaryKey: ['conversation_id', 'user_id'])
        .eq('user_id', _myUserId);
    final messageTrigger = _client.from('messages').stream(primaryKey: ['id']);

    return Rx.merge([
      membershipTrigger,
      messageTrigger,
    ]).startWith(const []).asyncMap((_) => fetchConversations());
  }

  Future<ConversationSummary?> fetchConversationSummary(
    String conversationId,
  ) async {
    final row = await _client
        .from('conversations')
        .select()
        .eq('id', conversationId)
        .maybeSingle();
    if (row == null) return null;

    final kind = row['kind'] == 'group'
        ? ConversationKind.group
        : ConversationKind.direct;
    AppProfile? peer;
    List<AppProfile>? members;
    if (kind == ConversationKind.direct) {
      final memberRow = await _client
          .from('conversation_members')
          .select('profiles!inner(*)')
          .eq('conversation_id', conversationId)
          .neq('user_id', _myUserId)
          .maybeSingle();
      if (memberRow != null) {
        peer = AppProfile.fromRow(
          memberRow['profiles'] as Map<String, dynamic>,
        );
      }
    } else {
      final memberRows = await _client
          .from('conversation_members')
          .select('profiles!inner(*)')
          .eq('conversation_id', conversationId)
          .neq('user_id', _myUserId);
      members = [
        for (final r in memberRows)
          AppProfile.fromRow(r['profiles'] as Map<String, dynamic>),
      ];
    }

    return ConversationSummary(
      id: conversationId,
      kind: kind,
      updatedAt: DateTime.parse(row['created_at'] as String).toLocal(),
      title: row['title'] as String?,
      peer: peer,
      members: members,
    );
  }

  Future<String> startDirectConversation(String otherUserId) async {
    final result = await _client.rpc(
      'create_direct_conversation',
      params: {'other_user_id': otherUserId},
    );
    return result as String;
  }

  /// [wrappedKeysByUserId] must include an entry for every member **and for
  /// this account itself** — each value is the group key sealed
  /// (`crypto_box_seal`) to that member's identity public key, computed
  /// entirely client-side before this call (see `new_group_sheet.dart`); the
  /// server only ever sees already-sealed ciphertext.
  Future<String> startGroupConversation({
    required String title,
    required Map<String, String> wrappedKeysByUserId,
  }) async {
    final result = await _client.rpc(
      'create_group_conversation',
      params: {
        'title': title,
        'members': [
          for (final entry in wrappedKeysByUserId.entries)
            {'user_id': entry.key, 'wrapped_key': entry.value},
        ],
      },
    );
    return result as String;
  }

  Stream<List<ChatMessage>> watchMessages(String conversationId) {
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        // Unlike the regular query builder (ascending by default),
        // SupabaseStreamBuilder.order() defaults to `ascending: false` —
        // without this explicit `true`, messages came back newest-first,
        // so new messages rendered at the *top* of the (non-reversed)
        // ListView instead of the bottom.
        .order('created_at', ascending: true)
        .map((rows) => rows.map(ChatMessage.fromRow).toList())
        .asyncMap((messages) async {
          await _prewarmSignalDecryption(messages);
          await _prewarmGroupKey(conversationId);
          return messages;
        });
  }

  /// Resolves edit events in [messages] (recording each into
  /// [_editOverrides], read back by [decryptText]) and strips them out —
  /// they exist purely to update another message's displayed text and are
  /// never rendered as their own bubble. Callers already have the
  /// conversation's `kind`/`peer` on hand (e.g. `chat_screen.dart`, which
  /// loads the conversation summary and message stream side by side), so
  /// this stays a plain method here rather than a parameter on
  /// [watchMessages] itself.
  List<ChatMessage> applyEditEvents(
    List<ChatMessage> messages, {
    required ConversationKind kind,
    AppProfile? peer,
  }) {
    _applyEditEvents(messages, kind: kind, peer: peer);
    return messages.where((m) => !m.isEditEvent).toList();
  }

  /// Every currently-pinned message in [conversationId], oldest first — the
  /// pinned banner shows the newest (last in this list) by default and
  /// cycles backwards through the rest on repeated taps, same as Telegram.
  Future<List<ChatMessage>> fetchPinnedMessages(String conversationId) async {
    final rows = await _client
        .from('messages')
        .select()
        .eq('conversation_id', conversationId)
        .not('pinned_at', 'is', null)
        .order('pinned_at', ascending: true);
    return rows.map(ChatMessage.fromRow).toList();
  }

  /// Any conversation member may pin/unpin — enforced server-side by the
  /// `toggle_message_pin` RPC, which only ever touches `pinned_at` (a
  /// non-sender could not use this to alter someone else's message content).
  Future<void> toggleMessagePin(String messageId, bool pin) {
    return _client.rpc(
      'toggle_message_pin',
      params: {'p_message_id': messageId, 'p_pin': pin},
    );
  }

  /// Hard-deletes the row (sender only, enforced by RLS — see
  /// `0007_hard_delete_messages.sql`). A deleted message has no reason to
  /// linger in the database at all; `messages.deleted_at` stays in the
  /// schema only so any row soft-deleted before this change (already
  /// scrubbed of ciphertext) is still recognized and skipped, not shown as
  /// "not yet decrypted".
  Future<void> deleteMessage(String messageId) {
    return _client
        .from('messages')
        .delete()
        .eq('id', messageId)
        .eq('sender_id', _myUserId);
  }

  /// [replyToId]/[editsMessageId]/[forwardedFromSenderId] are all optional
  /// markers on an otherwise-normal send — see `0006_conversation_message_actions.sql`.
  /// An edit (`editsMessageId` set) is never rendered as its own bubble; its
  /// decrypted text is recorded in [_editOverrides] for the message it edits.
  Future<void> sendDirectMessage({
    required String conversationId,
    required AppProfile peer,
    required String text,
    String? replyToId,
    String? editsMessageId,
    String? forwardedFromSenderId,
  }) async {
    final plaintext = Uint8List.fromList(utf8.encode(text));
    final signalMessage = await _signal.encryptForContact(peer, plaintext);

    final Map<String, dynamic> row;
    if (signalMessage != null) {
      row = {
        'conversation_id': conversationId,
        'sender_id': _myUserId,
        'ciphertext': base64Encode(signalMessage.serialized),
        'protocol': 'signal',
        'signal_message_type': signalMessage.messageType,
        'content_type': 'text',
      };
    } else {
      // Peer hasn't published Signal key material yet (hasn't opened the
      // app since forward secrecy shipped) — fall back to the legacy path
      // for this send so the message still goes through.
      final payload = _crypto.encryptDirectMessage(
        mySecretKey: _myKeyPair.secretKey,
        theirPublicKey: peer.identityPubkey,
        plaintext: plaintext,
      );
      row = {
        'conversation_id': conversationId,
        'sender_id': _myUserId,
        'ciphertext': base64Encode(payload.ciphertext),
        'nonce': base64Encode(payload.nonce),
        'protocol': 'crypto_box',
        'content_type': 'text',
      };
    }
    if (replyToId != null) row['reply_to_id'] = replyToId;
    if (editsMessageId != null) row['edits_message_id'] = editsMessageId;
    if (forwardedFromSenderId != null)
      row['forwarded_from_sender_id'] = forwardedFromSenderId;

    final inserted = await _client
        .from('messages')
        .insert(row)
        .select('id')
        .single();
    if (signalMessage != null) {
      await _rememberSentEcho(inserted['id'] as String, text);
    }
    if (editsMessageId != null) _editOverrides[editsMessageId] = text;
  }

  /// Sending to a group with no key at all (shouldn't normally happen —
  /// every member gets one sealed at creation time) is a real error, so
  /// this throws rather than silently no-op'ing like the Signal fallback
  /// does for direct messages.
  Future<void> sendGroupMessage({
    required String conversationId,
    required String text,
    String? replyToId,
    String? editsMessageId,
    String? forwardedFromSenderId,
  }) async {
    final groupKey = await _tryGroupKeyFor(conversationId);
    if (groupKey == null) {
      throw StateError(
        'No group key cached or published for conversation $conversationId',
      );
    }
    final payload = _crypto.encryptGroupMessage(
      groupKey: groupKey,
      conversationId: conversationId,
      plaintext: Uint8List.fromList(utf8.encode(text)),
    );
    await _client.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': _myUserId,
      'ciphertext': base64Encode(payload.ciphertext),
      'nonce': base64Encode(payload.nonce),
      'content_type': 'text',
      // `protocol` stays at its 'crypto_box' default here — it only
      // disambiguates within 1:1 messages (see decryptText); a message's
      // `ConversationKind` alone already fully determines that this row
      // uses the group AEAD scheme, not the legacy 1:1 crypto_box.
      if (replyToId != null) 'reply_to_id': replyToId,
      if (editsMessageId != null) 'edits_message_id': editsMessageId,
      if (forwardedFromSenderId != null)
        'forwarded_from_sender_id': forwardedFromSenderId,
    });
    if (editsMessageId != null) _editOverrides[editsMessageId] = text;
  }

  /// Re-encrypts an already-decrypted message fresh for [targetConversationId]
  /// — a forward is a normal independent message, not a reference to the
  /// original ciphertext (the target may use an entirely different protocol
  /// or group key). [originalSenderId] is kept only for the "Переслано от X"
  /// label.
  Future<void> forwardMessage({
    required String text,
    required String originalSenderId,
    required String targetConversationId,
    required ConversationKind targetKind,
    AppProfile? targetPeer,
  }) {
    if (targetKind == ConversationKind.group) {
      return sendGroupMessage(
        conversationId: targetConversationId,
        text: text,
        forwardedFromSenderId: originalSenderId,
      );
    }
    return sendDirectMessage(
      conversationId: targetConversationId,
      peer: targetPeer!,
      text: text,
      forwardedFromSenderId: originalSenderId,
    );
  }

  /// Encrypts [bytes] with a fresh per-file symmetric key (the same generic
  /// AEAD primitive as group text messages — nothing group-specific about
  /// it), uploads the ciphertext to the `media` storage bucket, and seals
  /// that key to every member of [recipients], **including the sender** —
  /// same reason group message keys are sealed to self too: otherwise the
  /// sender couldn't reopen their own sent media after a reload.
  ///
  /// [contentType] is `'image'` (rendered inline) or `'file'` — video also
  /// uses `'file'` with a `video/*` [mimeHint] rather than a third
  /// content_type, since there's no inline video playback yet; the mime
  /// hint is there for a future client to pick a video UI without a schema
  /// change.
  Future<void> sendMediaMessage({
    required String conversationId,
    required List<AppProfile> recipients,
    required Uint8List bytes,
    required String contentType,
    required String mimeHint,
    String? replyToId,
  }) async {
    final key = _crypto.generateGroupKey();
    try {
      final payload = _crypto.encryptGroupMessage(
        groupKey: key,
        conversationId: conversationId,
        plaintext: bytes,
      );
      final path = '$conversationId/${const Uuid().v4()}';
      await _client.storage
          .from('media')
          .uploadBinary(path, payload.ciphertext);

      final wrappedByUser = <String, String>{
        for (final p in recipients)
          p.id: base64Encode(
            _crypto.sealGroupKeyForMember(
              memberPublicKey: p.identityPubkey,
              groupKey: key,
            ),
          ),
      };

      await _client.from('messages').insert({
        'conversation_id': conversationId,
        'sender_id': _myUserId,
        'ciphertext': '',
        'content_type': contentType,
        'media_object_path': path,
        'media_wrapped_key': jsonEncode(wrappedByUser),
        'media_nonce': base64Encode(payload.nonce),
        'media_size_bytes': bytes.length,
        'media_mime_hint': mimeHint,
        if (replyToId != null) 'reply_to_id': replyToId,
      });
    } finally {
      key.dispose();
    }
  }

  /// Downloaded+decrypted media bytes, keyed by message id — a media
  /// message's key is unique per-message (unlike the shared group text key),
  /// so this caches per message rather than per conversation.
  final Map<String, Uint8List> _mediaCache = {};

  Future<Uint8List?> fetchAndDecryptMedia(ChatMessage message) async {
    final cached = _mediaCache[message.id];
    if (cached != null) return cached;
    final path = message.mediaObjectPath;
    final wrappedJson = message.mediaWrappedKey;
    final nonce = message.mediaNonce;
    if (path == null || wrappedJson == null || nonce == null) return null;

    final wrappedByUser = jsonDecode(wrappedJson) as Map<String, dynamic>;
    final myWrapped = wrappedByUser[_myUserId] as String?;
    if (myWrapped == null) return null;

    final ciphertext = await _client.storage.from('media').download(path);
    final key = _crypto.openSealedGroupKey(
      myKeyPair: _myKeyPair,
      sealed: base64Decode(myWrapped),
    );
    try {
      final bytes = _crypto.decryptGroupMessage(
        groupKey: key,
        conversationId: message.conversationId,
        payload: EncryptedPayload(ciphertext: ciphertext, nonce: nonce),
      );
      _mediaCache[message.id] = bytes;
      return bytes;
    } finally {
      key.dispose();
    }
  }

  /// Decrypts a message for display. Stays synchronous (called straight
  /// from `ListView.builder`'s `itemBuilder`) — for `protocol: 'signal'`
  /// and for group messages this only ever reads an already-resolved cache;
  /// the actual async decryption/key-unsealing happens ahead of time in
  /// [_prewarmSignalDecryption]/[_prewarmGroupKey], called from
  /// [watchMessages] and [fetchConversations] before either one hands
  /// messages to the UI.
  ///
  /// For `protocol: 'crypto_box'`, decryption itself is synchronous and
  /// works for messages I sent too — the shared secret is symmetric between
  /// the two parties regardless of direction.
  String decryptText(
    ChatMessage message, {
    required ConversationKind kind,
    AppProfile? peer,
  }) {
    if (message.deletedAt != null) return '🗑 Сообщение удалено';
    final override = _editOverrides[message.id];
    if (override != null) return override;
    // Media messages have no text ciphertext to decrypt at all — used for
    // reply-quote previews, the pinned banner, and the chat-list preview,
    // all of which just want a short label, not the actual bytes.
    if (message.contentType == 'image') return '📷 Фото';
    if (message.contentType == 'file') {
      final isVideo = message.mediaMimeHint?.startsWith('video/') ?? false;
      return isVideo ? '🎥 Видео' : '📎 Файл';
    }

    if (kind == ConversationKind.group) {
      final groupKey = _groupKeyCache[message.conversationId];
      if (groupKey == null) {
        return _groupKeyFailed.contains(message.conversationId)
            ? '🔒 Не удалось расшифровать'
            : '🔒 Расшифровка…';
      }
      try {
        final plaintext = _crypto.decryptGroupMessage(
          groupKey: groupKey,
          conversationId: message.conversationId,
          payload: EncryptedPayload(
            ciphertext: message.ciphertext,
            nonce: message.nonce ?? Uint8List(0),
          ),
        );
        return utf8.decode(plaintext);
      } catch (_) {
        return '🔒 Не удалось расшифровать';
      }
    }

    if (kind != ConversationKind.direct || peer == null) {
      return '🔒 Сообщение';
    }
    final echoed = _sentSignalEcho[message.id];
    if (echoed != null) return echoed;

    if (message.protocol == 'signal') {
      return _signalDecryptCache[message.id] ?? '🔒 Расшифровка…';
    }

    final payload = EncryptedPayload(
      ciphertext: message.ciphertext,
      nonce: message.nonce ?? Uint8List(0),
    );
    try {
      final plaintext = _crypto.decryptDirectMessage(
        mySecretKey: _myKeyPair.secretKey,
        theirPublicKey: peer.identityPubkey,
        payload: payload,
      );
      return utf8.decode(plaintext);
    } catch (_) {
      // Current key doesn't open it — try keys retired by a past "rotate my
      // key" action, oldest messages may predate the most recent rotation.
      for (final retiredBytes in _retiredKeysCache ?? const <Uint8List>[]) {
        final retiredKey = _crypto.wrapSecureKey(retiredBytes);
        try {
          final plaintext = _crypto.decryptDirectMessage(
            mySecretKey: retiredKey,
            theirPublicKey: peer.identityPubkey,
            payload: payload,
          );
          return utf8.decode(plaintext);
        } catch (_) {
          continue;
        } finally {
          retiredKey.dispose();
        }
      }
      return '🔒 Не удалось расшифровать';
    }
  }
}
