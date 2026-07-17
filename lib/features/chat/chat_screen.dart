import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

  Future<ChatMessage?>? _pinnedFuture;

  /// Multi-select mode, entered via a message's "Выбрать" action.
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
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
    setState(
      () => _pinnedFuture = chat?.fetchPinnedMessage(widget.conversationId),
    );
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
      if (m.deletedAt != null) continue;
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

  Future<void> _showMessageActions({
    required ChatMessage message,
    required String decryptedText,
    required ConversationSummary conversation,
    required bool mine,
  }) async {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final chat = ref.read(chatRepositoryProvider);
    final isPinned = message.pinnedAt != null;
    await showBlurredModalSheet<void>(
      context: context,
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
          _pinnedFuture ??= chat?.fetchPinnedMessage(widget.conversationId);
          final messages = ref.watch(
            messagesStreamProvider(widget.conversationId),
          );

          return Column(
            children: [
              if (_pinnedFuture != null)
                FutureBuilder<ChatMessage?>(
                  future: _pinnedFuture,
                  builder: (context, snapshot) {
                    final pinned = snapshot.data;
                    if (pinned == null) return const SizedBox.shrink();
                    final text =
                        chat?.decryptText(
                          pinned,
                          kind: conversation.kind,
                          peer: conversation.peer,
                        ) ??
                        '...';
                    return Container(
                      color: colors.surface,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.push_pin,
                            size: 16,
                            color: colors.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.textPrimary,
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
                            onPressed: () async {
                              await chat?.toggleMessagePin(pinned.id, false);
                              _refreshPinned();
                            },
                          ),
                        ],
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
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_scrollController.hasClients) {
                        _scrollController.jumpTo(
                          _scrollController.position.maxScrollExtent,
                        );
                      }
                    });
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

                        final bubble = GestureDetector(
                          onTap: _selecting
                              ? () => _toggleSelected(message.id)
                              : null,
                          onLongPress: _selecting
                              ? null
                              : () => _showMessageActions(
                                  message: message,
                                  decryptedText: text,
                                  conversation: conversation,
                                  mine: mine,
                                ),
                          child: Align(
                            alignment: mine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.75,
                              ),
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: mine ? colors.accent : colors.surface,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (message.forwardedFromSenderId != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 4,
                                        ),
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
                                      Container(
                                        margin: const EdgeInsets.only(
                                          bottom: 6,
                                        ),
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
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
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
                                    Text(
                                      text,
                                      style: TextStyle(
                                        color: mine
                                            ? colors.textOnAccent
                                            : colors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
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
                                  ],
                                ),
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
                          // Not wired up yet — media (M3) is on hold, this is
                          // just the visual slot for it.
                          IconButton(
                            iconSize: 26,
                            icon: Icon(
                              CupertinoIcons.paperclip,
                              color: colors.textSecondary.withValues(
                                alpha: 0.6,
                              ),
                            ),
                            onPressed: null,
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
                                  iconSize: 26,
                                  icon: Icon(
                                    _voiceMode
                                        ? CupertinoIcons.mic_fill
                                        : CupertinoIcons.camera_fill,
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
