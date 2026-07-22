import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../chat/chat_screen.dart';
import '../conversations/conversations_screen.dart';

/// Below this width the app is a single-column mobile layout: the chat list
/// is the whole screen and opening a chat pushes `/chats/:id`. At or above
/// it, a 2-column desktop layout: chat-list pane on the left, the selected
/// chat inline on the right.
const _wideBreakpoint = 900.0;

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _wideBreakpoint) {
          return const ConversationsScreen();
        }
        return const _WideLayout();
      },
    );
  }
}

class _WideLayout extends ConsumerWidget {
  const _WideLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final selectedId = ref.watch(selectedConversationIdProvider);

    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 360,
            child: SafeArea(
              right: false,
              child: const ConversationsScreen(embedded: true),
            ),
          ),
          VerticalDivider(width: 1, color: colors.border),
          Expanded(
            child: selectedId == null
                ? _EmptyDetail(colors: colors)
                : ChatScreen(
                    key: ValueKey(selectedId),
                    conversationId: selectedId,
                    onBack: () =>
                        ref
                                .read(selectedConversationIdProvider.notifier)
                                .state =
                            null,
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail({required this.colors});

  final AlbineColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 48,
            color: colors.textSecondary,
          ),
          const SizedBox(height: 12),
          Text(
            'Выбери чат, чтобы начать переписку',
            style: TextStyle(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
