import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/humanize_error.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../domain/models.dart';
import '../../shared/widgets/glass.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send(ConversationSummary conversation) async {
    final text = _textController.text.trim();
    final peer = conversation.peer;
    final chat = ref.read(chatRepositoryProvider);
    if (text.isEmpty || peer == null || chat == null) return;

    setState(() => _sending = true);
    _textController.clear();
    try {
      await chat.sendDirectMessage(
        conversationId: widget.conversationId,
        peerPublicKey: peer.identityPubkey,
        text: text,
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(conversationSummaryProvider(widget.conversationId));
    final myId = ref.watch(sessionControllerProvider).profile?.id;
    final chat = ref.watch(chatRepositoryProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        leading: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GlassIconButton(icon: Icons.arrow_back, size: 40, onPressed: () => context.go('/chats')),
        ),
        title: summaryAsync.value?.displayTitle ?? '...',
      ),
      body: GlassBackdrop(
        child: summaryAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: GlassErrorText(humanizeError(e))),
          data: (conversation) {
            if (conversation == null) {
              return const Center(child: Text('Чат не найден'));
            }
            if (conversation.kind != ConversationKind.direct) {
              return const Center(child: Text('Групповые чаты появятся позже'));
            }
            final messages = ref.watch(messagesStreamProvider(widget.conversationId));

            return Column(
              children: [
                const SizedBox(height: 88),
                Expanded(
                  child: messages.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: GlassErrorText(humanizeError(e))),
                    data: (items) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_scrollController.hasClients) {
                          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                        }
                      });
                      return ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final message = items[index];
                          final mine = message.senderId == myId;
                          final text = chat?.decryptText(
                                message,
                                kind: conversation.kind,
                                peer: conversation.peer,
                              ) ??
                              '...';
                          return Align(
                            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: mine
                                      ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.85)
                                      : Colors.white.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Text(
                                  text,
                                  style: TextStyle(color: mine ? const Color(0xFF0B0E14) : Colors.white),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: GlassContainer(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              hintText: 'Сообщение...',
                              hintStyle: TextStyle(color: Colors.white54),
                              border: InputBorder.none,
                            ),
                            onSubmitted: (_) => _send(conversation),
                          ),
                        ),
                        IconButton(
                          icon: _sending
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.send),
                          onPressed: _sending ? null : () => _send(conversation),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
