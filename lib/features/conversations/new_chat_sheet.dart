import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/humanize_error.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../shared/widgets/app_widgets.dart';

/// Opens a modal to look up a friend by exact username and start (or
/// resume) a direct conversation with them. Returns the conversation id.
Future<String?> showNewChatSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _NewChatSheet(),
  );
}

class _NewChatSheet extends ConsumerStatefulWidget {
  const _NewChatSheet();

  @override
  ConsumerState<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends ConsumerState<_NewChatSheet> {
  final _usernameController = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final me = ref.read(sessionControllerProvider).profile?.id;
    final profiles = ref.read(profileRepositoryProvider);
    final chat = ref.read(chatRepositoryProvider);

    final peer = await profiles.findByUsername(username);
    if (peer == null) {
      setState(() {
        _loading = false;
        _error = 'Пользователь "$username" не найден';
      });
      return;
    }
    if (peer.id == me || chat == null) {
      setState(() {
        _loading = false;
        _error = peer.id == me ? 'Это твой собственный аккаунт' : 'Сессия не готова';
      });
      return;
    }

    try {
      final conversationId = await chat.startDirectConversation(peer.id);
      if (mounted) Navigator.of(context).pop(conversationId);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = humanizeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Новый чат',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          LabeledField(
            label: 'Имя пользователя друга',
            controller: _usernameController,
            autofocus: true,
            onSubmitted: (_) => _start(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            AppErrorText(_error!),
          ],
          const SizedBox(height: 16),
          AppButton(label: 'Начать чат', loading: _loading, onPressed: _start),
        ],
      ),
    );
  }
}
