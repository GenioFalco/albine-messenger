import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/session_controller.dart';
import '../../shared/widgets/glass.dart';

/// Shown on every fresh page load to unlock the local key with the account
/// password. If this device has never held the key before (new device,
/// cleared storage), the same password entry transparently generates a new
/// one — there's no separate manual recovery step, same as any other
/// messenger app.
class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key});

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _passwordController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await ref.read(sessionControllerProvider.notifier).unlock(_passwordController.text);
    if (mounted) {
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  /// If the password was reset via email, the key wrapped under the old
  /// password can never unlock again — this starts fresh instead of
  /// leaving the user stuck on a permanent "wrong password" error.
  Future<void> _resetLocalKey() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await ref
        .read(sessionControllerProvider.notifier)
        .resetLocalKeyAndUnlock(_passwordController.text);
    if (mounted) {
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(sessionControllerProvider).profile;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: GlassContainer(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'С возвращением${profile != null ? ', ${profile.displayName}' : ''}',
                        style: Theme.of(
                          context,
                        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Введи пароль от аккаунта, чтобы открыть переписку на этом устройстве.',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
                      ),
                      const SizedBox(height: 20),
                      GlassTextField(
                        label: 'Пароль',
                        controller: _passwordController,
                        obscureText: true,
                        autofocus: true,
                        onSubmitted: (_) => _submit(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        GlassErrorText(_error!),
                        const SizedBox(height: 8),
                        GlassLink(
                          text: 'Недавно сбросил(а) пароль? Начать заново на этом устройстве',
                          onTap: _resetLocalKey,
                        ),
                      ],
                      const SizedBox(height: 20),
                      GlassButton(label: 'Продолжить', loading: _loading, onPressed: _submit),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => ref.read(sessionControllerProvider.notifier).signOut(),
                        child: const Text('Выйти из аккаунта'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
