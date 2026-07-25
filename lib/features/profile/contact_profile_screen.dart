import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../shared/widgets/app_widgets.dart';
import 'media_gallery_grid.dart';

/// A direct-chat peer's profile — avatar, display name, username, and the
/// media shared in this conversation. Opened by tapping the chat's AppBar
/// title.
class ContactProfileScreen extends ConsumerWidget {
  const ContactProfileScreen({
    super.key,
    required this.peer,
    required this.conversationId,
  });

  final AppProfile peer;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final chat = ref.watch(chatRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FormPanel(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: colors.surfaceStrong,
                  backgroundImage: peer.avatarUrl != null
                      ? NetworkImage(peer.avatarUrl!)
                      : null,
                  child: peer.avatarUrl != null
                      ? null
                      : Text(
                          peer.displayName.isNotEmpty
                              ? peer.displayName[0].toUpperCase()
                              : '?',
                          style: TextStyle(
                            fontSize: 30,
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
                const SizedBox(height: 14),
                Text(
                  peer.displayName,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '@${peer.username}',
                  style: TextStyle(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'Медиа, файлы',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (chat != null)
            FormPanel(
              padding: const EdgeInsets.all(4),
              child: MediaGalleryGrid(
                chat: chat,
                conversationId: conversationId,
              ),
            ),
        ],
      ),
    );
  }
}
