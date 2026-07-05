import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../shared/widgets/glass.dart';
import 'new_chat_sheet.dart';

class ConversationsScreen extends ConsumerWidget {
  const ConversationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(conversationsStreamProvider);
    final profile = ref.watch(sessionControllerProvider).profile;
    final glass = Theme.of(context).extension<AlbineGlass>()!;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: profile?.displayName ?? 'Чаты',
        actions: [
          GlassIconButton(
            icon: Icons.edit_outlined,
            onPressed: () async {
              final conversationId = await showNewChatSheet(context);
              if (conversationId != null && context.mounted) {
                context.push('/chats/$conversationId');
              }
            },
          ),
        ],
      ),
      body: GlassBackdrop(
        child: conversations.when(
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
              padding: const EdgeInsets.fromLTRB(12, 100, 12, 110),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final convo = items[index];
                return GlassCard(
                  onTap: () => context.push('/chats/${convo.id}'),
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
        ),
      ),
    );
  }
}
