import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/albine_theme.dart';
import '../../data/session_controller.dart';
import '../../shared/widgets/glass.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(sessionControllerProvider).profile;
    final glass = Theme.of(context).extension<AlbineGlass>()!;

    return GlassScaffold(
      backgroundColor: glass.background,
      appBar: GlassAppBar(title: const Text('Профиль')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          GlassContainer(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: glass.panelTintStrong,
                  child: Text(
                    (profile?.displayName.isNotEmpty ?? false)
                        ? profile!.displayName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      fontSize: 28,
                      color: glass.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  profile?.displayName ?? '...',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (profile != null) ...[
                  const SizedBox(height: 4),
                  Text('@${profile.username}', style: TextStyle(color: glass.textSecondary)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          GlassCard(
            onTap: () => ref.read(sessionControllerProvider.notifier).signOut(),
            child: Row(
              children: [
                Icon(Icons.logout, color: glass.textSecondary, size: 20),
                const SizedBox(width: 12),
                Text(
                  'Выйти из аккаунта',
                  style: TextStyle(fontWeight: FontWeight.w600, color: glass.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
