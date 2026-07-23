import 'dart:async';
import 'dart:html' as html;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/format.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../domain/models.dart';
import '../../shared/widgets/app_widgets.dart';

/// Either a day separator (shown once above the first message of that day)
/// or a message bubble — see `_ChatScreenState._buildListEntries`.
class _ChatListEntry {
  const _ChatListEntry.separator(this.separatorDay) : message = null;
  const _ChatListEntry.message(ChatMessage this.message) : separatorDay = null;

  final DateTime? separatorDay;
  final ChatMessage? message;
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId, this.onBack});

  final String conversationId;

  /// Called when the back button is tapped. Provided by the desktop 3-column
  /// shell to clear the inline selection instead of navigating; null (the
  /// default) falls back to `context.go('/chats')` for the pushed-route case
  /// on narrow/mobile layouts.
  final VoidCallback? onBack;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;

  /// Which icon the empty-input trailing button shows — toggled by tapping
  /// it, same as WhatsApp/Telegram. Neither voice nor video recording is
  /// wired up yet (M3 is on hold); this is just the visual affordance.
  bool _voiceMode = true;

  /// Set while composing a reply — mutually exclusive with [_editing].
  ChatMessage? _replyingTo;

  /// Set while editing a previously-sent message of mine — the input is
  /// pre-filled with its current text and sending calls `editsMessageId`
  /// instead of a normal send. See `chat_repository.dart`'s doc comment on
  /// `edits_message_id` for why this can't just overwrite the old ciphertext.
  ChatMessage? _editing;

  /// Hidden the instant a delete is initiated, rather than waiting for the
  /// realtime DELETE event to round-trip back through `messagesStreamProvider`
  /// — that round-trip can lag (or, on a stale/reconnecting websocket, not
  /// arrive promptly at all), which is why the message used to only
  /// disappear after leaving and re-entering the chat retriggered a fresh
  /// fetch. Never needs clearing: once the row really is gone server-side,
  /// it just stops appearing in `items` too, so the id sitting in this set
  /// forever is harmless.
  final Set<String> _locallyDeletedIds = {};

  Future<List<ChatMessage>>? _pinnedFuture;

  /// Which pinned message the banner currently shows, counting back from the
  /// newest (index 0). Tapping the banner scrolls to the current one, then
  /// advances to the next older pin, wrapping back to the newest — same
  /// cycling behavior as Telegram's pinned-message bar.
  int _pinnedIndex = 0;

  /// Multi-select mode, entered via a message's "Выбрать" action.
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  /// One stable key per rendered message, so [_scrollToMessage] can jump to
  /// an arbitrary earlier message (tapping a reply quote or the pinned
  /// banner) via `Scrollable.ensureVisible` regardless of item heights.
  /// `ListView.builder` recycles widgets, so these need to survive across
  /// rebuilds rather than being created fresh in itemBuilder each time.
  final Map<String, GlobalKey> _messageKeys = {};

  /// Briefly highlighted after a scroll-to-message jump, so landing on the
  /// target is obvious (same as Telegram) — cleared automatically.
  String? _highlightedMessageId;

  /// Suppresses the "jump to bottom on new message" behavior for the brief
  /// window right after a deliberate scroll-to-message, so the stream
  /// re-emitting (e.g. from a realtime update) doesn't immediately yank the
  /// view back to the bottom.
  bool _suppressAutoScroll = false;
  int _lastEntryCount = -1;

  /// Message ids already sent through `markMessagesRead` this session — a
  /// local dedupe so the same unread batch doesn't trigger a repeat network
  /// call on every rebuild (the update itself is already a no-op the second
  /// time, but there's no reason to keep asking).
  final Set<String> _markReadRequested = {};

  void _maybeMarkRead(List<ChatMessage> items, String? myId) {
    if (myId == null) return;
    final unread = items.where(
      (m) =>
          m.senderId != myId &&
          m.readAt == null &&
          !_markReadRequested.contains(m.id),
    );
    if (unread.isEmpty) return;
    _markReadRequested.addAll(unread.map((m) => m.id));
    ref.read(chatRepositoryProvider)?.markMessagesRead(widget.conversationId);
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToMessage(String id) {
    final ctx = _messageKeys[id]?.currentContext;
    if (ctx == null) return; // not currently rendered — no pagination yet
    _suppressAutoScroll = true;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.5,
    ).then((_) {
      _suppressAutoScroll = false;
    });
    setState(() => _highlightedMessageId = id);
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
  }

  void _enterSelection(String messageId) {
    setState(() {
      _selecting = true;
      _selectedIds
        ..clear()
        ..add(messageId);
    });
  }

  void _toggleSelected(String messageId) {
    setState(() {
      if (!_selectedIds.remove(messageId)) _selectedIds.add(messageId);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected() async {
    final chat = ref.read(chatRepositoryProvider);
    if (chat == null) return;
    final ids = List<String>.of(_selectedIds);
    _exitSelection();
    setState(() => _locallyDeletedIds.addAll(ids));
    for (final id in ids) {
      await chat.deleteMessage(id);
    }
  }

  Future<void> _forwardSelected(
    List<ChatMessage> currentItems,
    ConversationSummary conversation,
  ) async {
    final chat = ref.read(chatRepositoryProvider);
    if (chat == null) return;
    final selected =
        currentItems
            .where((m) => _selectedIds.contains(m.id) && m.deletedAt == null)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    _exitSelection();
    if (selected.isEmpty) return;

    final target = await showBlurredModalSheet<ConversationSummary>(
      context: context,
      maxWidth: 420,
      builder: (context) => const _ForwardPickerSheet(),
    );
    if (target == null || !mounted) return;
    try {
      for (final m in selected) {
        final text = chat.decryptText(
          m,
          kind: conversation.kind,
          peer: conversation.peer,
        );
        await chat.forwardMessage(
          text: text,
          originalSenderId: m.senderId,
          targetConversationId: target.id,
          targetKind: target.kind,
          targetPeer: target.peer,
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Переслано в «${target.displayTitle}»')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось переслать: ${humanizeError(e)}')),
        );
      }
    }
  }

  void _refreshPinned() {
    final chat = ref.read(chatRepositoryProvider);
    setState(() {
      _pinnedFuture = chat?.fetchPinnedMessages(widget.conversationId);
      _pinnedIndex = 0;
    });
  }

  void _startReply(ChatMessage message) {
    setState(() {
      _editing = null;
      _replyingTo = message;
    });
  }

  void _startEdit(ChatMessage message, String currentText) {
    setState(() {
      _replyingTo = null;
      _editing = message;
      _textController.text = currentText;
    });
  }

  void _cancelComposerExtras() {
    setState(() {
      _replyingTo = null;
      _editing = null;
      _textController.clear();
    });
  }

  Future<void> _send(ConversationSummary conversation) async {
    final text = _textController.text.trim();
    final chat = ref.read(chatRepositoryProvider);
    if (text.isEmpty || chat == null) return;
    if (conversation.kind == ConversationKind.direct &&
        conversation.peer == null)
      return;

    final editing = _editing;
    final replyTo = _replyingTo;
    setState(() => _sending = true);
    _textController.clear();
    try {
      if (conversation.kind == ConversationKind.group) {
        await chat.sendGroupMessage(
          conversationId: widget.conversationId,
          text: text,
          replyToId: replyTo?.id,
          editsMessageId: editing?.id,
        );
      } else {
        await chat.sendDirectMessage(
          conversationId: widget.conversationId,
          peer: conversation.peer!,
          text: text,
          replyToId: replyTo?.id,
          editsMessageId: editing?.id,
        );
      }
      if (mounted)
        setState(() {
          _replyingTo = null;
          _editing = null;
        });
    } catch (e) {
      // Without this, a thrown error (e.g. a group whose key this device
      // can no longer open) silently ate the typed text and left the user
      // with no feedback at all — restore it and surface what happened.
      if (mounted) {
        _textController.text = text;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось отправить: ${humanizeError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _senderName(
    String userId,
    ConversationSummary conversation,
    String? myId,
  ) {
    if (userId == myId) return 'Ты';
    if (conversation.peer?.id == userId) return conversation.peer!.displayName;
    for (final m in conversation.members ?? const []) {
      if (m.id == userId) return m.displayName;
    }
    return '...';
  }

  ChatMessage? _findById(List<ChatMessage> items, String? id) {
    if (id == null) return null;
    for (final m in items) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Interleaves a day-separator entry before the first message of each
  /// calendar day — [items] is already in ascending `createdAt` order.
  /// Deleted messages are dropped entirely rather than shown as a tombstone
  /// (matching Telegram: a deleted message just isn't there any more).
  List<_ChatListEntry> _buildListEntries(List<ChatMessage> items) {
    final entries = <_ChatListEntry>[];
    DateTime? lastDay;
    for (final m in items) {
      if (m.deletedAt != null || _locallyDeletedIds.contains(m.id)) continue;
      final day = DateTime(
        m.createdAt.year,
        m.createdAt.month,
        m.createdAt.day,
      );
      if (lastDay == null || day != lastDay) {
        entries.add(_ChatListEntry.separator(day));
        lastDay = day;
      }
      entries.add(_ChatListEntry.message(m));
    }
    return entries;
  }

  static const _imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
  };

  String _guessMime(String? extension) {
    switch (extension?.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'pdf':
        return 'application/pdf';
    }
    return 'application/octet-stream';
  }

  /// One tap on the paperclip, one native file dialog — no custom
  /// photo/video/file picker in between (the system dialog already lets you
  /// filter/browse, a second menu on top of it was redundant). What kind of
  /// attachment this is gets inferred from the picked file's extension.
  Future<void> _pickAndSendMedia(ConversationSummary conversation) async {
    final result = await FilePicker.pickFiles(withData: true);
    final file = result?.files.singleOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null || !mounted) return;

    final chat = ref.read(chatRepositoryProvider);
    final myProfile = ref.read(sessionControllerProvider).profile;
    if (chat == null || myProfile == null) return;

    final recipients = <AppProfile>[myProfile];
    if (conversation.kind == ConversationKind.group) {
      recipients.addAll(conversation.members ?? const []);
    } else if (conversation.peer != null) {
      recipients.add(conversation.peer!);
    } else {
      return;
    }

    final ext = file.extension?.toLowerCase();
    final contentType = _imageExtensions.contains(ext) ? 'image' : 'file';

    try {
      await chat.sendMediaMessage(
        conversationId: widget.conversationId,
        recipients: recipients,
        bytes: bytes,
        contentType: contentType,
        mimeHint: _guessMime(ext),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось отправить файл: ${humanizeError(e)}'),
          ),
        );
      }
    }
  }

  /// Single check = sent, double check (tinted, WhatsApp/Telegram-style) =
  /// read by the other side — see `0009_read_receipts.sql`. Only ever shown
  /// next to my own messages; there's nothing to show on an incoming one.
  Widget _statusTicks(
    ChatMessage message,
    AlbineColors colors, {
    required bool onImage,
  }) {
    final read = message.readAt != null;
    final baseColor = onImage ? Colors.white : colors.textOnAccent;
    return Icon(
      read ? Icons.done_all : Icons.done,
      size: onImage ? 12 : 13,
      color: read ? const Color(0xFF5AC8FA) : baseColor.withValues(alpha: 0.75),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

  /// Extension to give a downloaded file so it actually opens/previews as
  /// what it is — without this, the browser saved everything under a bare
  /// "file"/"video" name with no extension at all, so the OS had nothing to
  /// associate it with and it just looked like a generic, nameless blob.
  String _extensionForMime(String mime) {
    switch (mime) {
      case 'image/png':
        return 'png';
      case 'image/jpeg':
        return 'jpg';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'image/heic':
        return 'heic';
      case 'video/mp4':
        return 'mp4';
      case 'video/quicktime':
        return 'mov';
      case 'video/webm':
        return 'webm';
      case 'video/x-matroska':
        return 'mkv';
      case 'application/pdf':
        return 'pdf';
    }
    return 'bin';
  }

  Future<void> _downloadMedia(ChatMessage message) async {
    final chat = ref.read(chatRepositoryProvider);
    final bytes = await chat?.fetchAndDecryptMedia(message);
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось скачать файл')),
        );
      }
      return;
    }
    final mime = message.mediaMimeHint ?? 'application/octet-stream';
    final baseName = mime.startsWith('image/')
        ? 'photo'
        : (mime.startsWith('video/') ? 'video' : 'file');
    final filename = '$baseName.${_extensionForMime(mime)}';

    // Flutter Web has no filesystem access — this is the standard trick for
    // triggering a browser download of in-memory bytes (create a Blob,
    // point a throwaway <a download> at it, click it programmatically).
    final blob = html.Blob([bytes], mime);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  Future<void> _openMediaViewer(
    ChatMessage message, {
    required bool mine,
    required ConversationSummary conversation,
  }) async {
    final chat = ref.read(chatRepositoryProvider);
    final bytes = await chat?.fetchAndDecryptMedia(message);
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Не удалось загрузить')));
      }
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dialogContext) => _MediaViewerDialog(
        message: message,
        bytes: bytes,
        title: conversation.displayTitle,
        mine: mine,
        onDownload: () => _downloadMedia(message),
        onReply: () => _startReply(message),
        onForward: () => _forwardMessage(
          message,
          chat?.decryptText(
                message,
                kind: conversation.kind,
                peer: conversation.peer,
              ) ??
              '',
        ),
        onDelete: !mine
            ? null
            : () async {
                setState(() => _locallyDeletedIds.add(message.id));
                await chat?.deleteMessage(message.id);
              },
      ),
    );
  }

  Widget _buildMessageBody({
    required ChatMessage message,
    required String text,
    required bool mine,
    required AlbineColors colors,
    required ConversationSummary conversation,
  }) {
    final chat = ref.read(chatRepositoryProvider);
    if (message.contentType == 'image' && chat != null) {
      return FutureBuilder<Uint8List?>(
        future: chat.fetchAndDecryptMedia(message),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              width: 160,
              height: 160,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          final bytes = snapshot.data;
          if (bytes == null) {
            return Text(
              '📷 Не удалось загрузить фото',
              style: TextStyle(
                color: mine ? colors.textOnAccent : colors.textPrimary,
              ),
            );
          }
          // Tapping opens the full-screen viewer (close + download) instead
          // of just sitting inline forever — matches every other messenger.
          return GestureDetector(
            onTap: () => _openMediaViewer(
              message,
              mine: mine,
              conversation: conversation,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.memory(bytes, fit: BoxFit.cover, width: 220),
            ),
          );
        },
      );
    }

    if (message.contentType == 'file' && chat != null) {
      final isVideo = message.mediaMimeHint?.startsWith('video/') ?? false;
      final sizeLabel = message.mediaSizeBytes != null
          ? _formatFileSize(message.mediaSizeBytes!)
          : '';
      return InkWell(
        // A video opens the same full-screen viewer (now with playback);
        // a generic file just downloads straight away — no viewer makes
        // sense for an arbitrary file type.
        onTap: () => isVideo
            ? _openMediaViewer(message, mine: mine, conversation: conversation)
            : _downloadMedia(message),
        borderRadius: BorderRadius.circular(10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isVideo
                  ? CupertinoIcons.play_circle_fill
                  : CupertinoIcons.doc_fill,
              color: mine ? colors.textOnAccent : colors.textPrimary,
              size: 32,
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isVideo ? 'Видео' : 'Файл',
                  style: TextStyle(
                    color: mine ? colors.textOnAccent : colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  sizeLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: mine
                        ? colors.textOnAccent.withValues(alpha: 0.75)
                        : colors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Text(
      text,
      style: TextStyle(color: mine ? colors.textOnAccent : colors.textPrimary),
    );
  }

  Future<void> _showMessageActions({
    required ChatMessage message,
    required String decryptedText,
    required ConversationSummary conversation,
    required bool mine,
    Rect? anchorRect,
  }) async {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final chat = ref.read(chatRepositoryProvider);
    final isPinned = message.pinnedAt != null;
    await showBlurredModalSheet<void>(
      context: context,
      anchorRect: anchorRect,
      anchorAlignRight: mine,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          // A small copy of the message itself above the actions, same as
          // Telegram's long-press menu — reuses the same bubble colors/shape
          // as the real one so it reads as "this is the message you picked."
          Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            constraints: const BoxConstraints(maxWidth: 260),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: mine
                  ? colors.accent
                  : colors.background.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              decryptedText,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: mine ? colors.textOnAccent : colors.textPrimary,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            decoration: BoxDecoration(
              color: colors.background.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(colors.radius),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ActionSheetTile(
                    icon: CupertinoIcons.reply,
                    label: 'Ответить',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _startReply(message);
                    },
                  ),
                  ActionSheetTile(
                    icon: CupertinoIcons.doc_on_doc,
                    label: 'Скопировать',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      await Clipboard.setData(
                        ClipboardData(text: decryptedText),
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Скопировано')),
                        );
                      }
                    },
                  ),
                  // A forwarded message isn't something I authored, even when I'm
                  // the one who forwarded it — editing it wouldn't make sense
                  // (same as Telegram/WhatsApp: forwards aren't editable).
                  if (mine && message.forwardedFromSenderId == null)
                    ActionSheetTile(
                      icon: CupertinoIcons.pencil,
                      label: 'Редактировать',
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        _startEdit(message, decryptedText);
                      },
                    ),
                  ActionSheetTile(
                    icon: isPinned
                        ? CupertinoIcons.pin_slash
                        : CupertinoIcons.pin,
                    label: isPinned ? 'Открепить' : 'Закрепить',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      await chat?.toggleMessagePin(message.id, !isPinned);
                      _refreshPinned();
                    },
                  ),
                  ActionSheetTile(
                    icon: CupertinoIcons.arrowshape_turn_up_right,
                    label: 'Переслать',
                    onTap: () async {
                      Navigator.of(sheetContext).pop();
                      await _forwardMessage(message, decryptedText);
                    },
                  ),
                  if (mine)
                    ActionSheetTile(
                      icon: CupertinoIcons.delete,
                      label: 'Удалить',
                      destructive: true,
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        setState(() => _locallyDeletedIds.add(message.id));
                        await chat?.deleteMessage(message.id);
                      },
                    ),
                  Divider(height: 1, color: colors.border),
                  ActionSheetTile(
                    icon: CupertinoIcons.checkmark_circle,
                    label: 'Выбрать',
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _enterSelection(message.id);
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _forwardMessage(
    ChatMessage message,
    String decryptedText,
  ) async {
    final target = await showBlurredModalSheet<ConversationSummary>(
      context: context,
      maxWidth: 420,
      builder: (context) => const _ForwardPickerSheet(),
    );
    if (target == null || !mounted) return;
    final chat = ref.read(chatRepositoryProvider);
    if (chat == null) return;
    try {
      await chat.forwardMessage(
        text: decryptedText,
        originalSenderId: message.senderId,
        targetConversationId: target.id,
        targetKind: target.kind,
        targetPeer: target.peer,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Переслано в «${target.displayTitle}»')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось переслать: ${humanizeError(e)}')),
        );
      }
    }
  }

  Widget _buildTitle(BuildContext context, ConversationSummary? conversation) {
    final title = Text(conversation?.displayTitle ?? '...');
    if (conversation?.kind != ConversationKind.group) return title;

    // `members` holds only the *other* participants — +1 for me.
    final count = (conversation?.members?.length ?? 0) + 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        Text('$count участников', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(
      conversationSummaryProvider(widget.conversationId),
    );
    final myId = ref.watch(sessionControllerProvider).profile?.id;
    final chat = ref.watch(chatRepositoryProvider);
    final colors = Theme.of(context).extension<AlbineColors>()!;

    final currentMessages =
        ref.watch(messagesStreamProvider(widget.conversationId)).value ??
        const <ChatMessage>[];

    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(CupertinoIcons.xmark),
                onPressed: _exitSelection,
              ),
              title: Text('${_selectedIds.length} выбрано'),
              actions: [
                IconButton(
                  icon: const Icon(CupertinoIcons.arrowshape_turn_up_right),
                  onPressed:
                      (_selectedIds.isEmpty || summaryAsync.value == null)
                      ? null
                      : () => _forwardSelected(
                          currentMessages,
                          summaryAsync.value!,
                        ),
                ),
                IconButton(
                  icon: const Icon(CupertinoIcons.delete),
                  onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                ),
              ],
            )
          : AppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack ?? () => context.go('/chats'),
              ),
              title: _buildTitle(context, summaryAsync.value),
            ),
      body: summaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: AppErrorText(humanizeError(e))),
        data: (conversation) {
          if (conversation == null) {
            return const Center(child: Text('Чат не найден'));
          }
          _pinnedFuture ??= chat?.fetchPinnedMessages(widget.conversationId);
          final messages = ref.watch(
            messagesStreamProvider(widget.conversationId),
          );

          return Column(
            children: [
              if (_pinnedFuture != null)
                FutureBuilder<List<ChatMessage>>(
                  future: _pinnedFuture,
                  builder: (context, snapshot) {
                    final pins = snapshot.data ?? const <ChatMessage>[];
                    if (pins.isEmpty) return const SizedBox.shrink();
                    // pins is oldest-first; index 0 means "show the newest".
                    final index = _pinnedIndex % pins.length;
                    final pinned = pins[pins.length - 1 - index];
                    final text =
                        chat?.decryptText(
                          pinned,
                          kind: conversation.kind,
                          peer: conversation.peer,
                        ) ??
                        '...';
                    return Material(
                      color: colors.background,
                      child: InkWell(
                        onTap: () {
                          _scrollToMessage(pinned.id);
                          // Tapping again cycles to the next older pin, same
                          // as Telegram's pinned-message bar — wraps back to
                          // the newest after the oldest.
                          if (pins.length > 1) {
                            setState(
                              () => _pinnedIndex =
                                  (_pinnedIndex + 1) % pins.length,
                            );
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: colors.border),
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 3,
                                height: 32,
                                margin: const EdgeInsets.only(right: 10),
                                decoration: BoxDecoration(
                                  color: colors.accent,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'Закреплённое сообщение',
                                          style: TextStyle(
                                            color: colors.accent,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (pins.length > 1)
                                          Text(
                                            '  ${index + 1}/${pins.length}',
                                            style: TextStyle(
                                              color: colors.accent.withValues(
                                                alpha: 0.7,
                                              ),
                                              fontSize: 11,
                                            ),
                                          ),
                                      ],
                                    ),
                                    Text(
                                      text,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: colors.textPrimary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: Icon(
                                  CupertinoIcons.xmark,
                                  size: 16,
                                  color: colors.textSecondary,
                                ),
                                onPressed: () async {
                                  await chat?.toggleMessagePin(
                                    pinned.id,
                                    false,
                                  );
                                  _refreshPinned();
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              Expanded(
                child: messages.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) =>
                      Center(child: AppErrorText(humanizeError(e))),
                  data: (rawItems) {
                    final items =
                        chat?.applyEditEvents(
                          rawItems,
                          kind: conversation.kind,
                          peer: conversation.peer,
                        ) ??
                        rawItems;
                    final entries = _buildListEntries(items);
                    WidgetsBinding.instance.addPostFrameCallback(
                      (_) => _maybeMarkRead(items, myId),
                    );
                    // Only jump to the bottom when the list actually grew
                    // (a new message arrived) and nothing else is mid-scroll
                    // — otherwise a scroll-to-message jump (reply quote,
                    // pinned banner) gets immediately undone the next time
                    // the stream re-emits (e.g. a pin/mute toggle elsewhere
                    // touches conversation_members and retriggers this).
                    final grew = entries.length > _lastEntryCount;
                    _lastEntryCount = entries.length;
                    if (grew && !_suppressAutoScroll) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_scrollController.hasClients) {
                          _scrollController.jumpTo(
                            _scrollController.position.maxScrollExtent,
                          );
                        }
                      });
                    }
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final separatorDay = entry.separatorDay;
                        if (separatorDay != null) {
                          return Center(
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: colors.surface,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                formatDateSeparator(
                                  separatorDay,
                                  DateTime.now(),
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                          );
                        }

                        final message = entry.message!;
                        final mine = message.senderId == myId;

                        // Deleted messages are filtered out of `items`
                        // entirely by _buildListEntries — nothing to render
                        // for them, unlike WhatsApp's "this message was
                        // deleted" placeholder.

                        final text =
                            chat?.decryptText(
                              message,
                              kind: conversation.kind,
                              peer: conversation.peer,
                            ) ??
                            '...';
                        final replyTarget = _findById(items, message.replyToId);
                        final replyText = replyTarget == null
                            ? null
                            : chat?.decryptText(
                                replyTarget,
                                kind: conversation.kind,
                                peer: conversation.peer,
                              );
                        final selected = _selectedIds.contains(message.id);
                        final highlighted = _highlightedMessageId == message.id;
                        // Who's writing is otherwise only visible via bubble
                        // color/side — fine for a 1:1 chat, ambiguous once a
                        // group has 3+ people. Never shown for my own
                        // messages (obviously mine already).
                        final senderLabel =
                            conversation.kind == ConversationKind.group && !mine
                            ? _senderName(message.senderId, conversation, myId)
                            : null;
                        final messageKey = _messageKeys.putIfAbsent(
                          message.id,
                          () => GlobalKey(),
                        );

                        // A photo reads as a photo (edge-to-edge, rounded
                        // corners, time stamped directly on the image) —
                        // not as text with a colored bubble wrapped around
                        // it, same as every other messenger.
                        final isImage = message.contentType == 'image';
                        final messageBody = _buildMessageBody(
                          message: message,
                          text: text,
                          mine: mine,
                          colors: colors,
                          conversation: conversation,
                        );

                        final bubbleCore = Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: isImage
                              ? EdgeInsets.zero
                              : const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                          decoration: BoxDecoration(
                            color: isImage
                                ? Colors.transparent
                                : (mine ? colors.accent : colors.surface),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (message.forwardedFromSenderId != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    'Переслано от '
                                    '${_senderName(message.forwardedFromSenderId!, conversation, myId)}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontStyle: FontStyle.italic,
                                      color: mine
                                          ? colors.textOnAccent
                                          : colors.textSecondary,
                                    ),
                                  ),
                                ),
                              if (replyText != null)
                                GestureDetector(
                                  onTap: _selecting
                                      ? null
                                      : () => _scrollToMessage(replyTarget!.id),
                                  child: Container(
                                    margin: const EdgeInsets.only(bottom: 6),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color:
                                          (mine
                                                  ? colors.textOnAccent
                                                  : colors.textPrimary)
                                              .withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _senderName(
                                            replyTarget!.senderId,
                                            conversation,
                                            myId,
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: mine
                                                ? colors.textOnAccent
                                                : colors.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          replyText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: mine
                                                ? colors.textOnAccent
                                                : colors.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (isImage)
                                Stack(
                                  children: [
                                    messageBody,
                                    Positioned(
                                      right: 6,
                                      bottom: 6,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.45,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              formatMessageTime(
                                                message.createdAt,
                                              ),
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.white,
                                              ),
                                            ),
                                            if (mine) ...[
                                              const SizedBox(width: 3),
                                              _statusTicks(
                                                message,
                                                colors,
                                                onImage: true,
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              else ...[
                                messageBody,
                                const SizedBox(height: 2),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      formatMessageTime(message.createdAt),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: mine
                                            ? colors.textOnAccent.withValues(
                                                alpha: 0.75,
                                              )
                                            : colors.textSecondary,
                                      ),
                                    ),
                                    if (mine) ...[
                                      const SizedBox(width: 3),
                                      _statusTicks(
                                        message,
                                        colors,
                                        onImage: false,
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ],
                          ),
                        );

                        final bubbleWithSender = senderLabel == null
                            ? bubbleCore
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      right: 6,
                                      bottom: 2,
                                    ),
                                    child: CircleAvatar(
                                      radius: 14,
                                      backgroundColor: colors.surfaceStrong,
                                      child: Text(
                                        senderLabel.isNotEmpty
                                            ? senderLabel[0].toUpperCase()
                                            : '?',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: colors.textPrimary,
                                        ),
                                      ),
                                    ),
                                  ),
                                  Flexible(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 12,
                                            bottom: 2,
                                          ),
                                          child: Text(
                                            senderLabel,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: colors.accent,
                                            ),
                                          ),
                                        ),
                                        bubbleCore,
                                      ],
                                    ),
                                  ),
                                ],
                              );

                        final bubble = GestureDetector(
                          key: messageKey,
                          onTap: _selecting
                              ? () => _toggleSelected(message.id)
                              : null,
                          onLongPress: _selecting
                              ? null
                              : () {
                                  final box =
                                      messageKey.currentContext
                                              ?.findRenderObject()
                                          as RenderBox?;
                                  final rect = box != null
                                      ? box.localToGlobal(Offset.zero) &
                                            box.size
                                      : null;
                                  _showMessageActions(
                                    message: message,
                                    decryptedText: text,
                                    conversation: conversation,
                                    mine: mine,
                                    anchorRect: rect,
                                  );
                                },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 300),
                            color: highlighted
                                ? colors.accent.withValues(alpha: 0.15)
                                : Colors.transparent,
                            child: Align(
                              alignment: mine
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      MediaQuery.of(context).size.width * 0.75,
                                ),
                                child: bubbleWithSender,
                              ),
                            ),
                          ),
                        );

                        if (!_selecting) return bubble;
                        return Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              child: Icon(
                                selected
                                    ? CupertinoIcons.checkmark_alt_circle_fill
                                    : CupertinoIcons.circle,
                                size: 22,
                                color: selected
                                    ? colors.accent
                                    : colors.textSecondary,
                              ),
                            ),
                            Expanded(child: bubble),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyingTo != null || _editing != null)
                      Container(
                        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: BorderRadius.circular(colors.radius),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _editing != null
                                  ? Icons.edit_outlined
                                  : Icons.reply_outlined,
                              size: 18,
                              color: colors.textSecondary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _editing != null
                                    ? 'Редактирование сообщения'
                                    : 'Ответ на: '
                                          '${chat?.decryptText(_replyingTo!, kind: conversation.kind, peer: conversation.peer) ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.close,
                                size: 16,
                                color: colors.textSecondary,
                              ),
                              onPressed: _cancelComposerExtras,
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 12, 24),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Material(
                            color: colors.surface,
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () => _pickAndSendMedia(conversation),
                              child: SizedBox(
                                width: 42,
                                height: 42,
                                child: Icon(
                                  CupertinoIcons.paperclip,
                                  size: 22,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _textController,
                              style: TextStyle(color: colors.textPrimary),
                              minLines: 1,
                              maxLines: 5,
                              decoration: InputDecoration(
                                hintText: 'Сообщение...',
                                filled: true,
                                fillColor: colors.surface,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(
                                    colors.radius,
                                  ),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onSubmitted: (_) => _send(conversation),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _textController,
                            builder: (context, value, _) {
                              final hasText = value.text.trim().isNotEmpty;
                              if (!hasText && !_sending) {
                                // No text yet — voice/video-circle recording
                                // isn't wired up either, this just toggles
                                // which icon shows, same as WhatsApp/Telegram.
                                return IconButton(
                                  icon: _voiceMode
                                      ? Icon(
                                          CupertinoIcons.mic_fill,
                                          size: 26,
                                          color: colors.textSecondary,
                                        )
                                      // Cupertino's own camera glyph doesn't
                                      // read clearly as "rounded square with
                                      // a circle lens" at this size — drawn
                                      // by hand instead so the shape always
                                      // matches Telegram's icon exactly.
                                      : _CameraGlyph(
                                          size: 22,
                                          color: colors.textSecondary,
                                        ),
                                  onPressed: () =>
                                      setState(() => _voiceMode = !_voiceMode),
                                );
                              }
                              return Material(
                                color: colors.accent,
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: _sending
                                      ? null
                                      : () => _send(conversation),
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Center(
                                      child: _sending
                                          ? SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: colors.textOnAccent,
                                              ),
                                            )
                                          : Icon(
                                              _editing != null
                                                  ? CupertinoIcons.checkmark_alt
                                                  : CupertinoIcons.arrow_up,
                                              color: colors.textOnAccent,
                                              size: 20,
                                            ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A minimal conversation picker for "Переслать" — reuses the same
/// conversations stream as the main list, tapping a row returns it via
/// `Navigator.pop`.
class _ForwardPickerSheet extends ConsumerWidget {
  const _ForwardPickerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final conversations = ref.watch(conversationsStreamProvider);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      decoration: BoxDecoration(
        color: colors.background.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(colors.radius),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.6,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Переслать в...',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: conversations.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) =>
                      Center(child: AppErrorText(humanizeError(e))),
                  data: (items) => ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final convo = items[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: colors.surfaceStrong,
                          child: Text(
                            convo.displayTitle.isNotEmpty
                                ? convo.displayTitle[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        title: Text(convo.displayTitle),
                        onTap: () => Navigator.of(context).pop(convo),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen viewer for a tapped photo/video, styled after Telegram's own:
/// a nav-bar-style header (back, conversation title, "..." menu) instead of
/// a bare X, a bottom action row of enlarged versions of the same icons used
/// in the message long-press menu, and — for video — real transport controls
/// (scrub bar, skip ±15s, play/pause) with proper circular icon backgrounds
/// instead of bare white glyphs floating over the footage.
class _MediaViewerDialog extends StatefulWidget {
  const _MediaViewerDialog({
    required this.message,
    required this.bytes,
    required this.title,
    required this.mine,
    required this.onDownload,
    required this.onReply,
    required this.onForward,
    this.onDelete,
  });

  final ChatMessage message;
  final Uint8List bytes;
  final String title;

  /// Whether *I* sent this message — gates the "Удалить" action, same rule
  /// as the message long-press menu.
  final bool mine;
  final VoidCallback onDownload;
  final VoidCallback onReply;
  final VoidCallback onForward;
  final VoidCallback? onDelete;

  @override
  State<_MediaViewerDialog> createState() => _MediaViewerDialogState();
}

class _MediaViewerDialogState extends State<_MediaViewerDialog> {
  VideoPlayerController? _videoController;
  String? _blobUrl;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  bool get _isVideo =>
      widget.message.mediaMimeHint?.startsWith('video/') ?? false;

  @override
  void initState() {
    super.initState();
    if (_isVideo) {
      final blob = html.Blob([widget.bytes], widget.message.mediaMimeHint);
      final url = html.Url.createObjectUrlFromBlob(blob);
      _blobUrl = url;
      final controller = VideoPlayerController.networkUrl(Uri.parse(url))
        ..setLooping(false);
      _videoController = controller;
      controller
          .initialize()
          .then((_) {
            if (!mounted) return;
            setState(() {});
            // Browsers may reject autoplay here (no direct user gesture,
            // since this runs after an await) — that's fine, the play/pause
            // icon already reflects the real `isPlaying` state reactively;
            // just don't leave an unhandled rejection in the console.
            controller.play().catchError((_) {});
            _resetHideTimer();
          })
          .catchError((_) {});
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _videoController?.dispose();
    final url = _blobUrl;
    if (url != null) html.Url.revokeObjectUrl(url);
    super.dispose();
  }

  /// Controls fade out after a few seconds of playback so the video isn't
  /// permanently covered by an overlay — any tap on the video area (via
  /// [_toggleControlsOrPlayback]) brings them back and restarts the clock,
  /// same as every native video player.
  void _resetHideTimer() {
    _hideTimer?.cancel();
    final controller = _videoController;
    if (controller == null || !controller.value.isPlaying) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControlsOrPlayback() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      _resetHideTimer();
      return;
    }
    _togglePlayPause();
  }

  void _togglePlayPause() {
    final controller = _videoController;
    if (controller == null) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
        _hideTimer?.cancel();
      } else {
        controller.play().catchError((_) {});
        _resetHideTimer();
      }
      _controlsVisible = true;
    });
  }

  void _seekBy(Duration delta) {
    final controller = _videoController;
    if (controller == null) return;
    final duration = controller.value.duration;
    var target = controller.value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > duration) target = duration;
    controller.seekTo(target);
    _resetHideTimer();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = d.inHours;
    return hours > 0
        ? '$hours:$minutes:${seconds.padLeft(2, '0')}'
        : '$minutes:$seconds';
  }

  void _handleReply() {
    Navigator.of(context).pop();
    widget.onReply();
  }

  void _handleForward() {
    Navigator.of(context).pop();
    widget.onForward();
  }

  void _handleDelete() {
    Navigator.of(context).pop();
    widget.onDelete?.call();
  }

  /// "..." menu — same actions/icons as the message long-press menu
  /// (`_showMessageActions`), just reached from inside the viewer.
  Future<void> _showMoreMenu() async {
    await showBlurredModalSheet<void>(
      context: context,
      builder: (sheetContext) => Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).extension<AlbineColors>()!.background.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(
            Theme.of(context).extension<AlbineColors>()!.radius,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ActionSheetTile(
                icon: CupertinoIcons.reply,
                label: 'Ответить',
                onTap: _handleReply,
              ),
              ActionSheetTile(
                icon: CupertinoIcons.arrow_down_to_line,
                label: 'Сохранить',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.onDownload();
                },
              ),
              ActionSheetTile(
                icon: CupertinoIcons.arrowshape_turn_up_right,
                label: 'Переслать',
                onTap: _handleForward,
              ),
              if (widget.mine)
                ActionSheetTile(
                  icon: CupertinoIcons.delete,
                  label: 'Удалить',
                  destructive: true,
                  onTap: _handleDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A round icon button on a translucent dark backing — Telegram's viewer
  /// icons all sit on a filled circle, not a bare glyph floating over
  /// whatever's behind it (which is unreadable over a bright photo/video).
  /// No blur ("glassmorphism") — just a plain solid translucent fill, as
  /// asked for.
  Widget _circleIconButton({
    required IconData icon,
    required VoidCallback? onPressed,
    double diameter = 44,
    double iconSize = 22,
    String? tooltip,
  }) {
    final button = Material(
      color: Colors.black.withValues(alpha: 0.4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: Icon(icon, color: Colors.white, size: iconSize),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  Widget _topBar() {
    return Positioned(
      top: 4,
      left: 4,
      right: 4,
      child: Row(
        children: [
          _circleIconButton(
            icon: CupertinoIcons.back,
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                widget.title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          _circleIconButton(
            icon: CupertinoIcons.ellipsis,
            onPressed: _showMoreMenu,
          ),
        ],
      ),
    );
  }

  /// Enlarged versions of the same forward/delete icons from the message
  /// long-press menu, directly reachable without opening "..." — shared
  /// between photo and video so the chrome is identical either way. Save
  /// stays "..."-only (it was redundant to have it here too).
  Widget _bottomActionBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _circleIconButton(
          icon: CupertinoIcons.arrowshape_turn_up_right,
          onPressed: _handleForward,
          diameter: 52,
          iconSize: 26,
          tooltip: 'Переслать',
        ),
        if (widget.mine)
          _circleIconButton(
            icon: CupertinoIcons.delete,
            onPressed: _handleDelete,
            diameter: 52,
            iconSize: 26,
            tooltip: 'Удалить',
          ),
      ],
    );
  }

  Widget _videoControls(VideoPlayerController controller) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        return AnimatedOpacity(
          opacity: _controlsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !_controlsVisible,
            // Cancel the auto-hide clock the instant a finger goes down
            // anywhere on the controls (e.g. starting a scrub-bar drag) and
            // only restart it on release — otherwise a 3-second-old timer
            // could hide the controls (and, via IgnorePointer, stop
            // receiving input entirely) mid-drag.
            child: Listener(
              onPointerDown: (_) => _hideTimer?.cancel(),
              onPointerUp: (_) => _resetHideTimer(),
              child: Stack(
                children: [
                  // Dim the video slightly while the transport controls are
                  // up, same as every native player — makes the white
                  // play/pause + skip icons readable over any footage. Also
                  // tappable itself (this spans the *whole* screen, not just
                  // the video's own box, so there's dim area beside a
                  // narrow/portrait video too) so tapping anywhere still
                  // toggles play/pause like tapping the video does.
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: _toggleControlsOrPlayback,
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.15),
                      ),
                    ),
                  ),
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _circleIconButton(
                          icon: CupertinoIcons.gobackward_15,
                          onPressed: () =>
                              _seekBy(const Duration(seconds: -15)),
                          diameter: 52,
                          iconSize: 26,
                        ),
                        const SizedBox(width: 24),
                        _circleIconButton(
                          icon: value.isPlaying
                              ? CupertinoIcons.pause_fill
                              : CupertinoIcons.play_fill,
                          onPressed: _togglePlayPause,
                          diameter: 68,
                          iconSize: 34,
                        ),
                        const SizedBox(width: 24),
                        _circleIconButton(
                          icon: CupertinoIcons.goforward_15,
                          onPressed: () => _seekBy(const Duration(seconds: 15)),
                          diameter: 52,
                          iconSize: 26,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _VideoScrubBar(
                              controller: controller,
                              accentColor: Theme.of(
                                context,
                              ).extension<AlbineColors>()!.accent,
                            ),
                            const SizedBox(height: 2),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(value.position),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  _formatDuration(value.duration),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // Same forward/delete bar as the photo viewer —
                            // identical chrome either way, just fades with
                            // the rest of the video's transport controls
                            // instead of being permanently visible.
                            _bottomActionBar(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;
    final videoReady =
        _isVideo && controller != null && controller.value.isInitialized;

    final media = Center(
      child: _isVideo
          ? (videoReady
                ? AspectRatio(
                    // A zero/NaN aspect ratio (seen briefly on some browsers
                    // right as metadata loads) makes AspectRatio collapse to
                    // a zero-size box — the video area silently vanishes
                    // (just a black screen with the top bar) instead of
                    // erroring, since asserts are stripped in release
                    // builds.
                    aspectRatio:
                        controller.value.aspectRatio.isFinite &&
                            controller.value.aspectRatio > 0
                        ? controller.value.aspectRatio
                        : 16 / 9,
                    child: VideoPlayer(controller),
                  )
                : const CircularProgressIndicator(color: Colors.white))
          // `Center` gives an unbounded/loose constraint, and
          // `InteractiveViewer` doesn't constrain its child either — without
          // an explicit bounded box here, `Image.memory` has nothing to fit
          // *into*, so `BoxFit.contain` never actually applies and the photo
          // renders at its native pixel size (often several thousand px on a
          // phone photo) instead of scaled to the screen — this is what read
          // as "opens crooked/wrong": a huge image cropped to whatever
          // corner happened to land in the viewport.
          : LayoutBuilder(
              builder: (context, constraints) => InteractiveViewer(
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: Image.memory(widget.bytes, fit: BoxFit.contain),
                ),
              ),
            ),
    );

    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            // For video, the whole screen (not just the video's own,
            // possibly narrow/portrait box) needs to be a tap target for
            // revealing hidden controls again — otherwise tapping the
            // letterboxed margin beside a narrow video hits nothing (no
            // widget there at all once IgnorePointer disables the controls
            // layer) and the controls seem stuck gone.
            videoReady
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _toggleControlsOrPlayback,
                    child: media,
                  )
                : media,
            if (videoReady) Positioned.fill(child: _videoControls(controller)),
            if (!_isVideo)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: _bottomActionBar(),
                  ),
                ),
              ),
            _topBar(),
          ],
        ),
      ),
    );
  }
}

/// A bespoke scrub bar — not the stock `VideoProgressIndicator` (a thin flat
/// line in the library's own default styling), but a thicker rounded track
/// in the app's own accent color with a draggable thumb that grows slightly
/// while being dragged. Tap-to-seek and drag-to-scrub both hand-rolled via a
/// plain `GestureDetector` rather than the built-in widget's own gesture
/// handling.
class _VideoScrubBar extends StatefulWidget {
  const _VideoScrubBar({required this.controller, required this.accentColor});

  final VideoPlayerController controller;
  final Color accentColor;

  @override
  State<_VideoScrubBar> createState() => _VideoScrubBarState();
}

class _VideoScrubBarState extends State<_VideoScrubBar> {
  bool _dragging = false;
  double _dragFraction = 0;

  double _fractionFor(VideoPlayerValue value) {
    final durationMs = value.duration.inMilliseconds;
    if (durationMs <= 0) return 0;
    return (value.position.inMilliseconds / durationMs).clamp(0.0, 1.0);
  }

  void _seekToFraction(double fraction) {
    final duration = widget.controller.value.duration;
    widget.controller.seekTo(duration * fraction.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final fraction = _dragging ? _dragFraction : _fractionFor(value);
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            void updateFromDx(double dx) {
              setState(() => _dragFraction = (dx / width).clamp(0.0, 1.0));
            }

            final thumbDiameter = _dragging ? 16.0 : 12.0;
            final thumbX = (width * fraction) - thumbDiameter / 2;

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => _seekToFraction(d.localPosition.dx / width),
              onHorizontalDragStart: (d) {
                setState(() => _dragging = true);
                updateFromDx(d.localPosition.dx);
              },
              onHorizontalDragUpdate: (d) => updateFromDx(d.localPosition.dx),
              onHorizontalDragEnd: (_) {
                _seekToFraction(_dragFraction);
                setState(() => _dragging = false);
              },
              child: SizedBox(
                width: width,
                height: 24,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      top: 10,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 10,
                      left: 0,
                      width: width * fraction,
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: widget.accentColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 12 - thumbDiameter / 2,
                      left: thumbX,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: thumbDiameter,
                        height: thumbDiameter,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.accentColor,
                          boxShadow: const [
                            BoxShadow(
                              color: Colors.black45,
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// A hand-drawn "camera" glyph — rounded square body + a circle for the
/// lens — since Cupertino's own camera icon doesn't read clearly as that
/// shape at small sizes. Matches Telegram's camera icon.
class _CameraGlyph extends StatelessWidget {
  const _CameraGlyph({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final strokeWidth = size * 0.09;
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: Container(
          width: size,
          height: size * 0.86,
          decoration: BoxDecoration(
            border: Border.all(color: color, width: strokeWidth),
            borderRadius: BorderRadius.circular(size * 0.28),
          ),
          child: Center(
            child: Container(
              width: size * 0.42,
              height: size * 0.42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color, width: strokeWidth),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
