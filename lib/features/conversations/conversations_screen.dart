import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../shared/widgets/glass.dart';
import 'new_chat_sheet.dart';

/// The chat list. Used two ways:
/// - Narrow/mobile: a full [GlassScaffold] screen; tapping a conversation
///   pushes `/chats/:id` as a new route.
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
    final glass = Theme.of(context).extension<AlbineGlass>()!;

    final list = conversations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassErrorText(humanizeError(error)),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Text(
              'Пока нет чатов.\nНажми ✎ сверху, чтобы написать другу.',
              textAlign: TextAlign.center,
              style: TextStyle(color: glass.textSecondary),
            ),
          );
        }
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(12, embedded ? 4 : 100, 12, embedded ? 12 : 110),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final convo = items[index];
            final selected = embedded && convo.id == selectedId;
            return GlassCard(
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
                    backgroundColor: glass.panelTintStrong,
                    child: Text(
                      convo.displayTitle.isNotEmpty ? convo.displayTitle[0].toUpperCase() : '?',
                      style: TextStyle(color: glass.textPrimary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          convo.displayTitle,
                          style: TextStyle(fontWeight: FontWeight.w600, color: glass.textPrimary),
                        ),
                        if (convo.previewText != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              convo.previewText!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: glass.textSecondary),
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
                GlassIconButton(
                  icon: const Icon(Icons.edit_outlined),
                  size: 40,
                  onPressed: () => _startNewChat(context, ref),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: GlassTextField.search(placeholder: 'Поиск'),
          ),
          const SizedBox(height: 4),
          Expanded(child: list),
        ],
      );
    }

    return GlassScaffold(
      backgroundColor: glass.background,
      appBar: GlassAppBar(
        title: Text(profile?.displayName ?? 'Чаты'),
        actions: [
          GlassIconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _startNewChat(context, ref)),
        ],
      ),
      body: list,
    );
  }
}
