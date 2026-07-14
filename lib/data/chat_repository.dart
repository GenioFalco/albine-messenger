import 'dart:convert';
import 'dart:typed_data';

import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models.dart';
import '../services/crypto/crypto_models.dart';
import '../services/crypto/crypto_service.dart';
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
  }) : _client = client,
       _crypto = crypto,
       _myKeyPair = myKeyPair,
       _myUserId = myUserId,
       _signal = signal;

  final SupabaseClient _client;
  final CryptoService _crypto;
  final IdentityKeyPair _myKeyPair;
  final String _myUserId;
  final SignalService _signal;

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
    for (final m in messages) {
      if (m.protocol != 'signal') continue;
      if (_sentSignalEcho.containsKey(m.id) || _signalDecryptCache.containsKey(m.id)) continue;

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
        final plaintext = await _signal.decryptFromContact(m.senderId, m.ciphertext, messageType);
        _signalDecryptCache[m.id] = utf8.decode(plaintext);
      } catch (_) {
        _signalDecryptCache[m.id] = '🔒 Не удалось расшифровать';
      }
    }
  }

  /// This device's copy of each group's symmetric key, unsealed once and
  /// cached — group AEAD decryption is otherwise synchronous, so this is the
  /// only async step, same "prewarm before the sync UI read" shape as
  /// [_signalDecryptCache].
  final Map<String, SecureKey> _groupKeyCache = {};

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

    final key = _crypto.openSealedGroupKey(myKeyPair: _myKeyPair, sealed: base64Decode(wrapped));
    _groupKeyCache[conversationId] = key;
    return key;
  }

  Future<void> _prewarmGroupKey(String conversationId) async {
    try {
      await _tryGroupKeyFor(conversationId);
    } catch (_) {
      // Leave uncached; decryptText falls back to its placeholder text.
    }
  }

  Future<List<ConversationSummary>> fetchConversations() async {
    final memberRows = await _client
        .from('conversation_members')
        .select('conversation_id, conversations!inner(id, kind, title, created_at)')
        .eq('user_id', _myUserId);

    if (memberRows.isEmpty) return [];

    final conversationIds = [for (final r in memberRows) r['conversation_id'] as String];

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

    final lastMessageByConversation = <String, ChatMessage>{};
    for (final row in messageRows) {
      final msg = ChatMessage.fromRow(row);
      lastMessageByConversation.putIfAbsent(msg.conversationId, () => msg);
    }

    final summaries = <ConversationSummary>[];
    for (final r in memberRows) {
      final convo = r['conversations'] as Map<String, dynamic>;
      final id = convo['id'] as String;
      final kind = convo['kind'] == 'group' ? ConversationKind.group : ConversationKind.direct;
      final others = othersByConversation[id] ?? const <AppProfile>[];
      final peer = kind == ConversationKind.direct && others.isNotEmpty ? others.first : null;
      final members = kind == ConversationKind.group ? others : null;
      final lastMessage = lastMessageByConversation[id];

      var updatedAt = DateTime.parse(convo['created_at'] as String).toLocal();
      String? preview;
      if (lastMessage != null) {
        updatedAt = lastMessage.createdAt;
        await _prewarmSignalDecryption([lastMessage]);
        await _prewarmGroupKey(id);
        preview = decryptText(lastMessage, kind: kind, peer: peer);
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
        ),
      );
    }

    summaries.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return summaries;
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

    return Rx.merge([membershipTrigger, messageTrigger])
        .startWith(const [])
        .asyncMap((_) => fetchConversations());
  }

  Future<ConversationSummary?> fetchConversationSummary(String conversationId) async {
    final row = await _client.from('conversations').select().eq('id', conversationId).maybeSingle();
    if (row == null) return null;

    final kind = row['kind'] == 'group' ? ConversationKind.group : ConversationKind.direct;
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
        peer = AppProfile.fromRow(memberRow['profiles'] as Map<String, dynamic>);
      }
    } else {
      final memberRows = await _client
          .from('conversation_members')
          .select('profiles!inner(*)')
          .eq('conversation_id', conversationId)
          .neq('user_id', _myUserId);
      members = [for (final r in memberRows) AppProfile.fromRow(r['profiles'] as Map<String, dynamic>)];
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
        .order('created_at')
        .map((rows) => rows.map(ChatMessage.fromRow).toList())
        .asyncMap((messages) async {
          await _prewarmSignalDecryption(messages);
          await _prewarmGroupKey(conversationId);
          return messages;
        });
  }

  Future<void> sendDirectMessage({
    required String conversationId,
    required AppProfile peer,
    required String text,
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

    final inserted = await _client.from('messages').insert(row).select('id').single();
    if (signalMessage != null) {
      await _rememberSentEcho(inserted['id'] as String, text);
    }
  }

  /// Sending to a group with no key at all (shouldn't normally happen —
  /// every member gets one sealed at creation time) is a real error, so
  /// this throws rather than silently no-op'ing like the Signal fallback
  /// does for direct messages.
  Future<void> sendGroupMessage({required String conversationId, required String text}) async {
    final groupKey = await _tryGroupKeyFor(conversationId);
    if (groupKey == null) {
      throw StateError('No group key cached or published for conversation $conversationId');
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
    });
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
  String decryptText(ChatMessage message, {required ConversationKind kind, AppProfile? peer}) {
    if (kind == ConversationKind.group) {
      final groupKey = _groupKeyCache[message.conversationId];
      if (groupKey == null) return '🔒 Расшифровка…';
      try {
        final plaintext = _crypto.decryptGroupMessage(
          groupKey: groupKey,
          conversationId: message.conversationId,
          payload: EncryptedPayload(ciphertext: message.ciphertext, nonce: message.nonce ?? Uint8List(0)),
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

    try {
      final plaintext = _crypto.decryptDirectMessage(
        mySecretKey: _myKeyPair.secretKey,
        theirPublicKey: peer.identityPubkey,
        payload: EncryptedPayload(ciphertext: message.ciphertext, nonce: message.nonce ?? Uint8List(0)),
      );
      return utf8.decode(plaintext);
    } catch (_) {
      return '🔒 Не удалось расшифровать';
    }
  }
}
