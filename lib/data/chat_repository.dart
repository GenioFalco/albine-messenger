import 'dart:convert';
import 'dart:typed_data';

import 'package:rxdart/rxdart.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models.dart';
import '../services/crypto/crypto_models.dart';
import '../services/crypto/crypto_service.dart';

/// All chat data access + the encrypt/decrypt boundary. UI code never touches
/// ciphertext or the Supabase client directly — it goes through here.
///
/// v1 scope: direct (1:1) conversations only. `ConversationKind.group` is
/// modelled in the schema and in [CryptoService] already, so M2 extends this
/// repository without a migration; there's just no group-sending path yet.
class ChatRepository {
  ChatRepository({
    required SupabaseClient client,
    required CryptoService crypto,
    required IdentityKeyPair myKeyPair,
    required String myUserId,
  }) : _client = client,
       _crypto = crypto,
       _myKeyPair = myKeyPair,
       _myUserId = myUserId;

  final SupabaseClient _client;
  final CryptoService _crypto;
  final IdentityKeyPair _myKeyPair;
  final String _myUserId;

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

    final peerByConversation = <String, AppProfile>{
      for (final r in otherMemberRows)
        r['conversation_id'] as String: AppProfile.fromRow(r['profiles'] as Map<String, dynamic>),
    };

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
      final peer = peerByConversation[id];
      final lastMessage = lastMessageByConversation[id];

      var updatedAt = DateTime.parse(convo['created_at'] as String).toLocal();
      String? preview;
      if (lastMessage != null) {
        updatedAt = lastMessage.createdAt;
        preview = decryptText(lastMessage, kind: kind, peer: peer);
      }

      summaries.add(
        ConversationSummary(
          id: id,
          kind: kind,
          updatedAt: updatedAt,
          title: convo['title'] as String?,
          peer: peer,
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
    }

    return ConversationSummary(
      id: conversationId,
      kind: kind,
      updatedAt: DateTime.parse(row['created_at'] as String).toLocal(),
      title: row['title'] as String?,
      peer: peer,
    );
  }

  Future<String> startDirectConversation(String otherUserId) async {
    final result = await _client.rpc(
      'create_direct_conversation',
      params: {'other_user_id': otherUserId},
    );
    return result as String;
  }

  Stream<List<ChatMessage>> watchMessages(String conversationId) {
    return _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', conversationId)
        .order('created_at')
        .map((rows) => rows.map(ChatMessage.fromRow).toList());
  }

  Future<void> sendDirectMessage({
    required String conversationId,
    required Uint8List peerPublicKey,
    required String text,
  }) async {
    final payload = _crypto.encryptDirectMessage(
      mySecretKey: _myKeyPair.secretKey,
      theirPublicKey: peerPublicKey,
      plaintext: Uint8List.fromList(utf8.encode(text)),
    );
    await _client.from('messages').insert({
      'conversation_id': conversationId,
      'sender_id': _myUserId,
      'ciphertext': base64Encode(payload.ciphertext),
      'nonce': base64Encode(payload.nonce),
      'content_type': 'text',
    });
  }

  /// Decrypts a message. Works for messages I sent too — crypto_box's shared
  /// secret is symmetric between the two parties regardless of direction.
  String decryptText(ChatMessage message, {required ConversationKind kind, AppProfile? peer}) {
    if (kind != ConversationKind.direct || peer == null) {
      return '🔒 Сообщение';
    }
    try {
      final plaintext = _crypto.decryptDirectMessage(
        mySecretKey: _myKeyPair.secretKey,
        theirPublicKey: peer.identityPubkey,
        payload: EncryptedPayload(ciphertext: message.ciphertext, nonce: message.nonce),
      );
      return utf8.decode(plaintext);
    } catch (_) {
      return '🔒 Не удалось расшифровать';
    }
  }
}
