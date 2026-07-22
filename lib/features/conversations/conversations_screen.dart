import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/format.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../domain/models.dart';
import '../../shared/widgets/app_widgets.dart';
import 'new_chat_sheet.dart';
import 'new_group_sheet.dart';

/// The chat list. Used two ways:
/// - Narrow/mobile: a full [Scaffold] screen; tapping a conversation pushes
///   `/chats/:id`.
/// - Wide/desktop (`embedded: true`): the left pane of the 2-column shell —
///   header + search + list + a profile button pinned at the bottom; tapping
///   a conversation updates [selectedConversationIdProvider] so the detail
///   pane swaps inline.
class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<ConversationsScreen> createState() =>
      _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  final _filterController = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  Future<void> _startNewChat() async {
    final conversationId = await showNewChatSheet(context);
    if (conversationId == null || !mounted) return;
    if (widget.embedded) {
      ref.read(selectedConversationIdProvider.notifier).state = conversationId;
    } else {
      context.push('/chats/$conversationId');
    }
  }

  Future<void> _startNewGroup() async {
    final conversationId = await showNewGroupSheet(context);
    if (conversationId == null || !mounted) return;
    if (widget.embedded) {
      ref.read(selectedConversationIdProvider.notifier).state = conversationId;
    } else {
      context.push('/chats/$conversationId');
    }
  }

  void _openConversation(String id) {
    if (widget.embedded) {
      ref.read(selectedConversationIdProvider.notifier).state = id;
    } else {
      context.push('/chats/$id');
    }
  }

  Future<void> _showNewConversationMenu() async {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    await showBlurredModalSheet<void>(
      context: context,
      builder: (sheetContext) => Container(
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
                icon: CupertinoIcons.person,
                label: 'Личное сообщение',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _startNewChat();
                },
              ),
              ActionSheetTile(
                icon: CupertinoIcons.person_2,
                label: 'Групповой чат',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _startNewGroup();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _togglePinned(ConversationSummary convo) async {
    final chat = ref.read(chatRepositoryProvider);
    if (chat == null) return;
    await chat.setConversationPinned(convo.id, !convo.isPinned);
  }

  Future<void> _toggleMuted(ConversationSummary convo) async {
    final chat = ref.read(chatRepositoryProvider);
    if (chat == null) return;
    await chat.setConversationMuted(convo.id, !convo.muted);
  }

  Future<void> _deleteConversation(ConversationSummary convo) async {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.background,
        title: const Text('Удалить чат?'),
        content: Text(
          'Чат «${convo.displayTitle}» пропадёт из списка. Если придёт новое сообщение, он появится снова.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final chat = ref.read(chatRepositoryProvider);
    if (chat == null) return;
    await chat.hideConversation(convo.id);
  }

  Future<void> _showTileMenu(ConversationSummary convo) async {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    await showBlurredModalSheet<void>(
      context: context,
      builder: (sheetContext) => Container(
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
                icon: convo.isPinned
                    ? CupertinoIcons.pin_slash
                    : CupertinoIcons.pin,
                label: convo.isPinned ? 'Открепить' : 'Закрепить',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _togglePinned(convo);
                },
              ),
              ActionSheetTile(
                icon: convo.muted
                    ? CupertinoIcons.bell
                    : CupertinoIcons.bell_slash,
                label: convo.muted ? 'Включить звук' : 'Отключить звук',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _toggleMuted(convo);
                },
              ),
              ActionSheetTile(
                icon: CupertinoIcons.delete,
                label: 'Удалить',
                destructive: true,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _deleteConversation(convo);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationsStreamProvider);
    final selectedId = widget.embedded
        ? ref.watch(selectedConversationIdProvider)
        : null;
    final colors = Theme.of(context).extension<AlbineColors>()!;

    final searchField = Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TextField(
        controller: _filterController,
        onChanged: (v) => setState(() => _filter = v.trim().toLowerCase()),
        style: TextStyle(color: colors.textPrimary),
        decoration: InputDecoration(
          hintText: 'Поиск по чатам',
          prefixIcon: Icon(Icons.search, color: colors.textSecondary),
          filled: true,
          fillColor: colors.surface,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(colors.radius),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(colors.radius),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );

    final list = conversations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            humanizeError(error),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
      ),
      data: (items) {
        final filtered = _filter.isEmpty
            ? items
            : items
                  .where((c) => c.displayTitle.toLowerCase().contains(_filter))
                  .toList();

        if (filtered.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                items.isEmpty
                    ? 'Пока нет чатов.\nНажми ✎, чтобы найти друга.'
                    : 'Ничего не найдено',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          );
        }

        final now = DateTime.now();
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final convo = filtered[index];
            return _ConversationTile(
              convo: convo,
              selected: widget.embedded && convo.id == selectedId,
              now: now,
              onTap: () => _openConversation(convo.id),
              onLongPress: () => _showTileMenu(convo),
              onPin: () => _togglePinned(convo),
              onMute: () => _toggleMuted(convo),
              onDelete: () => _deleteConversation(convo),
            );
          },
        );
      },
    );

    // ---- Desktop left pane ----
    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Чаты',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'Новый чат',
                  onPressed: _showNewConversationMenu,
                ),
              ],
            ),
          ),
          searchField,
          Expanded(child: list),
          Divider(height: 1, color: colors.border),
          _ProfileButton(),
        ],
      );
    }

    // ---- Mobile full screen ----
    final profile = ref.watch(sessionControllerProvider).profile;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: GestureDetector(
            onTap: () => context.push('/profile'),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: colors.surfaceStrong,
              child: Text(
                (profile?.displayName.isNotEmpty ?? false)
                    ? profile!.displayName[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        title: const Text('Albine'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Новый чат',
            onPressed: _showNewConversationMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          searchField,
          Expanded(child: list),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.convo,
    required this.selected,
    required this.now,
    required this.onTap,
    required this.onLongPress,
    required this.onPin,
    required this.onMute,
    required this.onDelete,
  });

  final ConversationSummary convo;
  final bool selected;
  final DateTime now;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onPin;
  final VoidCallback onMute;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Slidable(
        key: ValueKey(convo.id),
        startActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.28,
          children: [
            SlidableAction(
              onPressed: (_) => onPin(),
              backgroundColor: colors.accent,
              foregroundColor: colors.textOnAccent,
              icon: convo.isPinned
                  ? CupertinoIcons.pin_slash
                  : CupertinoIcons.pin,
              label: convo.isPinned ? 'Открепить' : 'Закрепить',
              borderRadius: BorderRadius.circular(colors.radius),
            ),
          ],
        ),
        endActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.5,
          children: [
            SlidableAction(
              onPressed: (_) => onMute(),
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              icon: convo.muted
                  ? CupertinoIcons.bell
                  : CupertinoIcons.bell_slash,
              label: convo.muted ? 'Вкл. звук' : 'Без звука',
              borderRadius: BorderRadius.circular(colors.radius),
            ),
            SlidableAction(
              onPressed: (_) => onDelete(),
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              icon: CupertinoIcons.delete,
              label: 'Удалить',
              borderRadius: BorderRadius.circular(colors.radius),
            ),
          ],
        ),
        child: Material(
          color: selected ? colors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(colors.radius),
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            borderRadius: BorderRadius.circular(colors.radius),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: colors.surfaceStrong,
                    child: Text(
                      convo.displayTitle.isNotEmpty
                          ? convo.displayTitle[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (convo.isPinned) ...[
                              Icon(
                                CupertinoIcons.pin_fill,
                                size: 14,
                                color: colors.textSecondary,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                convo.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  color: colors.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              formatChatTimestamp(convo.updatedAt, now),
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                convo.previewText ?? 'Нет сообщений',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            if (convo.muted) ...[
                              const SizedBox(width: 4),
                              Icon(
                                CupertinoIcons.bell_slash,
                                size: 15,
                                color: colors.textSecondary,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Profile row pinned at the bottom of the desktop chat-list pane.
class _ProfileButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final profile = ref.watch(sessionControllerProvider).profile;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push('/profile'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: colors.surfaceStrong,
                child: Text(
                  (profile?.displayName.isNotEmpty ?? false)
                      ? profile!.displayName[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile?.displayName ?? '...',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    if (profile != null)
                      Text(
                        '@${profile.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              Icon(
                Icons.settings_outlined,
                color: colors.textSecondary,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
