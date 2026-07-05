import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/session_controller.dart';
import '../../shared/widgets/glass.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(sessionControllerProvider).profile;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: const GlassAppBar(title: 'Профиль'),
      body: GlassBackdrop(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 100, 16, 120),
            children: [
              GlassContainer(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 36,
                      backgroundColor: Colors.white12,
                      child: Text(
                        (profile?.displayName.isNotEmpty ?? false)
                            ? profile!.displayName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(fontSize: 28, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      profile?.displayName ?? '...',
                      style: Theme.of(
                        context,
                      ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (profile != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        '@${profile.username}',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              GlassCard(
                onTap: () => ref.read(sessionControllerProvider.notifier).signOut(),
                child: const Row(
                  children: [
                    Icon(Icons.logout, color: Colors.white70, size: 20),
                    SizedBox(width: 12),
                    Text('Выйти из аккаунта', style: TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
