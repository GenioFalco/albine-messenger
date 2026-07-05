import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/theme/albine_theme.dart';
import '../../domain/models.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';

/// Opens the "find friends" search as a bottom sheet. Returns the id of the
/// conversation that was started/opened, or null if dismissed.
Future<String?> showNewChatSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => const _NewChatSheet(),
  );
}

class _NewChatSheet extends ConsumerStatefulWidget {
  const _NewChatSheet();

  @override
  ConsumerState<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends ConsumerState<_NewChatSheet> {
  final _searchController = TextEditingController();
  List<AppProfile> _results = [];
  bool _loading = false;
  int _requestId = 0;
  String? _error;
  bool _searchedOnce = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final trimmed = query.trim();
    final myId = ref.read(sessionControllerProvider).profile?.id;
    final reqId = ++_requestId;

    if (trimmed.isEmpty || myId == null) {
      setState(() {
        _results = [];
        _loading = false;
        _searchedOnce = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await ref
          .read(profileRepositoryProvider)
          .searchProfiles(trimmed, excludeUserId: myId);
      if (reqId != _requestId) return; // a newer keystroke superseded this one
      setState(() {
        _results = results;
        _loading = false;
        _searchedOnce = true;
      });
    } catch (e) {
      if (reqId != _requestId) return;
      setState(() {
        _loading = false;
        _error = humanizeError(e);
      });
    }
  }

  Future<void> _openChat(AppProfile peer) async {
    final chat = ref.read(chatRepositoryProvider);
    if (chat == null) return;
    try {
      final conversationId = await chat.startDirectConversation(peer.id);
      if (mounted) Navigator.of(context).pop(conversationId);
    } catch (e) {
      setState(() => _error = humanizeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Новый чат',
                    style: Theme.of(
                      context,
                    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _searchController,
                    autofocus: true,
                    onChanged: _search,
                    style: TextStyle(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Найти по имени пользователя',
                      prefixIcon: Icon(Icons.search, color: colors.textSecondary),
                      filled: true,
                      fillColor: colors.surface,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(colors.radius),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(colors.radius),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(colors.radius),
                        borderSide: BorderSide(color: colors.accent, width: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody(colors)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AlbineColors colors) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: colors.textSecondary)),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searchedOnce) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Введи имя пользователя друга,\nчтобы начать переписку',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text('Никого не нашлось', style: TextStyle(color: colors.textSecondary)),
      );
    }
    return ListView.builder(
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final p = _results[index];
        return ListTile(
          leading: CircleAvatar(
            radius: 22,
            backgroundColor: colors.surfaceStrong,
            child: Text(
              p.displayName.isNotEmpty ? p.displayName[0].toUpperCase() : '?',
              style: TextStyle(color: colors.textPrimary, fontWeight: FontWeight.w600),
            ),
          ),
          title: Text(
            p.displayName,
            style: TextStyle(fontWeight: FontWeight.w600, color: colors.textPrimary),
          ),
          subtitle: Text('@${p.username}', style: TextStyle(color: colors.textSecondary)),
          onTap: () => _openChat(p),
        );
      },
    );
  }
}
