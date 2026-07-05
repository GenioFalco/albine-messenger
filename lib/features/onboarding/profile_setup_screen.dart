import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/albine_theme.dart';
import '../../data/session_controller.dart';
import '../../shared/widgets/glass.dart';

class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final error = await ref
        .read(sessionControllerProvider.notifier)
        .setUpProfile(username: _usernameController.text, displayName: _displayNameController.text);
    if (mounted) {
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackdrop(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: FormPanel(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Почти готово',
                        style: Theme.of(
                          context,
                        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Придумай имя пользователя, под которым тебя увидят друзья.',
                        style: TextStyle(color: glass.textSecondary),
                      ),
                      const SizedBox(height: 24),
                      LabeledGlassField(
                        label: 'Имя пользователя',
                        controller: _usernameController,
                        autofocus: true,
                      ),
                      const SizedBox(height: 12),
                      LabeledGlassField(label: 'Отображаемое имя', controller: _displayNameController),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        GlassErrorText(_error!),
                      ],
                      const SizedBox(height: 20),
                      LayoutBuilder(
                        builder: (context, constraints) => GlassButton.custom(
                          width: constraints.maxWidth,
                          height: 54,
                          enabled: !_loading,
                          onTap: _submit,
                          child: _loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2.4),
                                )
                              : const Text('Продолжить', style: TextStyle(fontWeight: FontWeight.w600)),
                        ),
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
