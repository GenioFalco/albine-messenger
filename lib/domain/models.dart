import 'dart:convert';
import 'dart:typed_data';

class AppProfile {
  const AppProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.identityPubkey,
    this.avatarUrl,
  });

  final String id;
  final String username;
  final String displayName;
  final Uint8List identityPubkey;
  final String? avatarUrl;

  factory AppProfile.fromRow(Map<String, dynamic> row) => AppProfile(
    id: row['id'] as String,
    username: row['username'] as String,
    displayName: row['display_name'] as String,
    identityPubkey: base64Decode(row['identity_pubkey'] as String),
    avatarUrl: row['avatar_url'] as String?,
  );
}

enum ConversationKind { direct, group }

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.kind,
    required this.updatedAt,
    this.title,
    this.peer,
    this.previewText,
  });

  final String id;
  final ConversationKind kind;
  final DateTime updatedAt;
  final String? title;

  /// The other participant, only set for direct conversations.
  final AppProfile? peer;

  final String? previewText;

  String get displayTitle => kind == ConversationKind.direct
      ? (peer?.displayName ?? peer?.username ?? '...')
      : (title ?? 'Группа');
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.ciphertext,
    required this.nonce,
    required this.contentType,
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final Uint8List ciphertext;
  final Uint8List nonce;
  final String contentType;
  final DateTime createdAt;

  factory ChatMessage.fromRow(Map<String, dynamic> row) => ChatMessage(
    id: row['id'] as String,
    conversationId: row['conversation_id'] as String,
    senderId: row['sender_id'] as String,
    ciphertext: base64Decode(row['ciphertext'] as String),
    nonce: base64Decode(row['nonce'] as String),
    contentType: row['content_type'] as String,
    createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
  );
}
