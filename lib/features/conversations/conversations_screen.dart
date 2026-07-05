import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../shared/widgets/app_widgets.dart';
import 'new_chat_sheet.dart';

/// The chat list. Used two ways:
/// - Narrow/mobile: a full [Scaffold] screen; tapping a conversation pushes
///   `/chats/:id` as a new route.
/// - Wide/desktop (`embedded: true`): just the list pane of the 3-column
///   shell; tapping a conversation updates [selectedConversationIdProvider]
///   so the detail column next to it swaps inline — no navigation.
class ConversationsScreen extends ConsumerWidget {
  const ConversationsScreen({super.key, this.embedded = false});

  final bool embedded;

  Future<void> _startNewChat(BuildContext context, WidgetRef ref) async {
    final conversationId = await showNewChatSheet(context);
    if (conversationId == null || !context.mounted) return;
    if (embedded) {
      ref.read(selectedConversationIdProvider.notifier).state = conversationId;
    } else {
      context.push('/chats/$conversationId');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationsStreamProvider);
    final profile = ref.watch(sessionControllerProvider).profile;
    final selectedId = embedded ? ref.watch(selectedConversationIdProvider) : null;
    final colors = Theme.of(context).extension<AlbineColors>()!;

    final list = conversations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppErrorText(humanizeError(error)),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Text(
              'Пока нет чатов.\nНажми ✎ сверху, чтобы написать другу.',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          itemCount: items.length,
          separatorBuilder: (context, index) => const SizedBox(height: 2),
          itemBuilder: (context, index) {
            final convo = items[index];
            final selected = embedded && convo.id == selectedId;
            return AppCard(
              highlighted: selected,
              onTap: () {
                if (embedded) {
                  ref.read(selectedConversationIdProvider.notifier).state = convo.id;
                } else {
                  context.push('/chats/${convo.id}');
                }
              },
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: colors.surfaceStrong,
                    child: Text(
                      convo.displayTitle.isNotEmpty ? convo.displayTitle[0].toUpperCase() : '?',
                      style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          convo.displayTitle,
                          style: TextStyle(fontWeight: FontWeight.w600, color: colors.textPrimary),
                        ),
                        if (convo.previewText != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              convo.previewText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: colors.textSecondary),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Чаты',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                AppIconButton(
                  icon: Icons.edit_outlined,
                  size: 36,
                  onPressed: () => _startNewChat(context, ref),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: list),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(profile?.displayName ?? 'Чаты'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _startNewChat(context, ref),
          ),
        ],
      ),
      body: list,
    );
  }
}
