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
    this.pinnedAt,
    this.muted = false,
    this.hiddenAt,
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

  /// This account's own preferences for this conversation — read from *my*
  /// `conversation_members` row, never the other member's.
  final DateTime? pinnedAt;
  final bool muted;

  /// Set when I "deleted" this chat — hides it from my list until a newer
  /// message arrives (see [isHidden]). Never affects the other member(s).
  final DateTime? hiddenAt;

  bool get isPinned => pinnedAt != null;

  /// Hidden unless a message has arrived since I hid it — mirrors
  /// WhatsApp/Telegram's "delete chat" (per-device, reappears on a new
  /// message rather than being gone forever).
  bool get isHidden => hiddenAt != null && !updatedAt.isAfter(hiddenAt!);

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
    this.deletedAt,
    this.replyToId,
    this.pinnedAt,
    this.forwardedFromSenderId,
    this.editsMessageId,
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

  /// Soft-delete marker — set by the sender, message is shown as a tombstone
  /// instead of being decrypted.
  final DateTime? deletedAt;

  /// The message this one is replying to, if any (same conversation only).
  final String? replyToId;

  /// Set (by any conversation member, via the `toggle_message_pin` RPC) when
  /// this message is pinned in its conversation.
  final DateTime? pinnedAt;

  /// Original sender, set only on a forwarded copy — for the "Переслано от
  /// X" label. The forwarded row is otherwise an independent message with
  /// its own fresh ciphertext, not a reference to the original.
  final String? forwardedFromSenderId;

  /// Set when this row is an *edit event* rather than a visible message: its
  /// ciphertext decrypts to the new text for the message with this id. See
  /// `0006_conversation_message_actions.sql` for why edits can't just
  /// overwrite the original ciphertext in place.
  final String? editsMessageId;

  bool get isEditEvent => editsMessageId != null;

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
    deletedAt: row['deleted_at'] == null ? null : DateTime.parse(row['deleted_at'] as String).toLocal(),
    replyToId: row['reply_to_id'] as String?,
    pinnedAt: row['pinned_at'] == null ? null : DateTime.parse(row['pinned_at'] as String).toLocal(),
    forwardedFromSenderId: row['forwarded_from_sender_id'] as String?,
    editsMessageId: row['edits_message_id'] as String?,
  );
}
