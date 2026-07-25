import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/pick_image.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../domain/models.dart';
import '../../shared/widgets/app_widgets.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _uploadingAvatar = false;

  Future<void> _changeAvatar() async {
    final profile = ref.read(sessionControllerProvider).profile;
    if (profile == null) return;
    final picked = await pickImageBytes();
    if (picked == null || !mounted) return;

    setState(() => _uploadingAvatar = true);
    try {
      final url = await ref
          .read(profileRepositoryProvider)
          .uploadAvatar(
            userId: profile.id,
            bytes: picked.bytes,
            mime: picked.mime,
          );
      if (!mounted) return;
      ref
          .read(sessionControllerProvider.notifier)
          .updateProfile(
            AppProfile(
              id: profile.id,
              username: profile.username,
              displayName: profile.displayName,
              identityPubkey: profile.identityPubkey,
              avatarUrl: url,
              signalRegistrationId: profile.signalRegistrationId,
            ),
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось загрузить фото: ${humanizeError(e)}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(sessionControllerProvider).profile;
    final colors = Theme.of(context).extension<AlbineColors>()!;

    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FormPanel(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                GestureDetector(
                  onTap: _uploadingAvatar ? null : _changeAvatar,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: colors.surfaceStrong,
                        backgroundImage: profile?.avatarUrl != null
                            ? NetworkImage(profile!.avatarUrl!)
                            : null,
                        child: profile?.avatarUrl != null
                            ? null
                            : Text(
                                (profile?.displayName.isNotEmpty ?? false)
                                    ? profile!.displayName[0].toUpperCase()
                                    : '?',
                                style: TextStyle(
                                  fontSize: 28,
                                  color: colors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                      if (_uploadingAvatar)
                        const CircularProgressIndicator(strokeWidth: 2)
                      else
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colors.accent,
                              border: Border.all(
                                color: colors.background,
                                width: 2,
                              ),
                            ),
                            child: const Icon(
                              Icons.camera_alt,
                              size: 14,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
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
                    style: TextStyle(color: colors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'Безопасность',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          AppCard(
            onTap: () => _showRotateKeyDialog(context, ref),
            child: Row(
              children: [
                Icon(
                  Icons.security_outlined,
                  color: colors.textSecondary,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Сбросить ключ шифрования',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Если подозреваешь, что устройство могли взломать — старая переписка '
                        'останется читаемой на этом устройстве, но украденный ключ перестанет '
                        'работать для новых сообщений.',
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          AppCard(
            onTap: () => ref.read(sessionControllerProvider.notifier).signOut(),
            child: Row(
              children: [
                Icon(Icons.logout, color: colors.textSecondary, size: 20),
                const SizedBox(width: 12),
                Text(
                  'Выйти из аккаунта',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showRotateKeyDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (context) => const _RotateKeyDialog(),
    );
  }
}

class _RotateKeyDialog extends ConsumerStatefulWidget {
  const _RotateKeyDialog();

  @override
  ConsumerState<_RotateKeyDialog> createState() => _RotateKeyDialogState();
}

class _RotateKeyDialogState extends ConsumerState<_RotateKeyDialog> {
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await ref
        .read(sessionControllerProvider.notifier)
        .rotateIdentityKey(_passwordController.text);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = error;
      _done = error == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;

    if (_done) {
      return AlertDialog(
        backgroundColor: colors.background,
        title: const Text('Готово'),
        content: const Text(
          'Новый ключ создан и опубликован. Старые сообщения по-прежнему читаются.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      );
    }

    return AlertDialog(
      backgroundColor: colors.background,
      title: const Text('Сбросить ключ шифрования?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Подтверди паролем от аккаунта. Старая переписка останется читаемой только на этом '
            'устройстве; украденная копия ключа перестанет работать для новых сообщений.',
            style: TextStyle(color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          LabeledField(
            label: 'Пароль',
            controller: _passwordController,
            obscureText: true,
            autofocus: true,
            onSubmitted: (_) => _confirm(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            AppErrorText(_error!),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('Отмена'),
        ),
        TextButton(
          onPressed: _loading ? null : _confirm,
          child: const Text('Сбросить'),
        ),
      ],
    );
  }
}
