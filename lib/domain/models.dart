import 'dart:convert';
import 'dart:typed_data';

class AppProfile {
  const AppProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.identityPubkey,
    this.avatarUrl,
    this.signalRegistrationId,
  });

  final String id;
  final String username;
  final String displayName;
  final Uint8List identityPubkey;
  final String? avatarUrl;

  /// Null until this account has bootstrapped its Signal (forward-secrecy)
  /// key material at least once — see `SignalService.ensureBootstrapped`.
  /// Messaging a peer with no registration id yet falls back to crypto_box.
  final int? signalRegistrationId;

  factory AppProfile.fromRow(Map<String, dynamic> row) => AppProfile(
    id: row['id'] as String,
    username: row['username'] as String,
    displayName: row['display_name'] as String,
    identityPubkey: base64Decode(row['identity_pubkey'] as String),
    avatarUrl: row['avatar_url'] as String?,
    signalRegistrationId: row['signal_registration_id'] as int?,
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
    this.members,
    this.previewText,
  });

  final String id;
  final ConversationKind kind;
  final DateTime updatedAt;
  final String? title;

  /// The other participant, only set for direct conversations.
  final AppProfile? peer;

  /// The other participants, only set for group conversations (mirrors
  /// [peer]'s direct-only convention — exactly one of the two is non-null).
  final List<AppProfile>? members;

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
    required this.protocol,
    this.signalMessageType,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final Uint8List ciphertext;

  /// Only meaningful for `protocol == 'crypto_box'` — a serialized Signal
  /// ciphertext carries its own nonce/ratchet metadata internally.
  final Uint8List? nonce;
  final String contentType;
  final DateTime createdAt;

  /// 'crypto_box' (legacy, static X25519 box) or 'signal' (Double Ratchet,
  /// forward-secret). See `ROADMAP.md` M1.5.
  final String protocol;

  /// Only set for `protocol == 'signal'` — libsignal's `CiphertextMessage`
  /// type (2 = whisper/ratchet, 3 = prekey/session-establishing), needed to
  /// pick the right parser on decrypt.
  final int? signalMessageType;

  factory ChatMessage.fromRow(Map<String, dynamic> row) => ChatMessage(
    id: row['id'] as String,
    conversationId: row['conversation_id'] as String,
    senderId: row['sender_id'] as String,
    ciphertext: base64Decode(row['ciphertext'] as String),
    nonce: row['nonce'] == null ? null : base64Decode(row['nonce'] as String),
    contentType: row['content_type'] as String,
    createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
    protocol: row['protocol'] as String? ?? 'crypto_box',
    signalMessageType: row['signal_message_type'] as int?,
  );
}
