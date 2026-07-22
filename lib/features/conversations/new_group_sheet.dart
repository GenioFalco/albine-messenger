import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../domain/models.dart';
import '../../shared/widgets/app_widgets.dart';

/// Opens the "create group" flow as a bottom sheet. Returns the id of the
/// created conversation, or null if dismissed.
Future<String?> showNewGroupSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => const _NewGroupSheet(),
  );
}

class _NewGroupSheet extends ConsumerStatefulWidget {
  const _NewGroupSheet();

  @override
  ConsumerState<_NewGroupSheet> createState() => _NewGroupSheetState();
}

class _NewGroupSheetState extends ConsumerState<_NewGroupSheet> {
  final _titleController = TextEditingController();
  final _searchController = TextEditingController();
  List<AppProfile> _results = [];
  final Map<String, AppProfile> _selected = {};
  bool _loading = false;
  bool _creating = false;
  int _requestId = 0;
  String? _error;
  bool _searchedOnce = false;

  @override
  void dispose() {
    _titleController.dispose();
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
      });
      return;
    }

    setState(() => _loading = true);

    try {
      final results = await ref
          .read(profileRepositoryProvider)
          .searchProfiles(trimmed, excludeUserId: myId);
      if (reqId != _requestId) return; // a newer keystroke superseded this one
      setState(() {
        _results = results.where((p) => !_selected.containsKey(p.id)).toList();
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

  void _toggle(AppProfile profile) {
    setState(() {
      if (_selected.containsKey(profile.id)) {
        _selected.remove(profile.id);
      } else {
        _selected[profile.id] = profile;
        _results = _results.where((p) => p.id != profile.id).toList();
      }
    });
  }

  Future<void> _createGroup() async {
    final title = _titleController.text.trim();
    final myProfile = ref.read(sessionControllerProvider).profile;
    final chat = ref.read(chatRepositoryProvider);
    final crypto = ref.read(cryptoServiceProvider);
    if (title.isEmpty || _selected.isEmpty || myProfile == null || chat == null)
      return;

    setState(() {
      _creating = true;
      _error = null;
    });

    final groupKey = crypto.generateGroupKey();
    try {
      // The plaintext group key only ever exists transiently here — each
      // member (including me) gets it sealed to their own identity public
      // key (crypto_box_seal); the server only ever sees the sealed output.
      final wrappedKeys = <String, String>{
        myProfile.id: base64Encode(
          crypto.sealGroupKeyForMember(
            memberPublicKey: myProfile.identityPubkey,
            groupKey: groupKey,
          ),
        ),
        for (final member in _selected.values)
          member.id: base64Encode(
            crypto.sealGroupKeyForMember(
              memberPublicKey: member.identityPubkey,
              groupKey: groupKey,
            ),
          ),
      };

      final conversationId = await chat.startGroupConversation(
        title: title,
        wrappedKeysByUserId: wrappedKeys,
      );
      if (mounted) Navigator.of(context).pop(conversationId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = humanizeError(e);
        });
      }
    } finally {
      groupKey.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final canCreate =
        !_creating &&
        _titleController.text.trim().isNotEmpty &&
        _selected.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Новая группа',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _titleController,
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Название группы',
                      filled: true,
                      fillColor: colors.surface,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(colors.radius),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (_selected.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final member in _selected.values)
                          Chip(
                            label: Text(member.displayName),
                            onDeleted: () => _toggle(member),
                            backgroundColor: colors.surfaceStrong,
                            side: BorderSide.none,
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _searchController,
                    onChanged: _search,
                    style: TextStyle(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Добавить участников',
                      prefixIcon: Icon(
                        Icons.search,
                        color: colors.textSecondary,
                      ),
                      filled: true,
                      fillColor: colors.surface,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(colors.radius),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildResults(colors)),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  children: [
                    if (_error != null) ...[
                      AppErrorText(_error!),
                      const SizedBox(height: 12),
                    ],
                    AppButton(
                      label: 'Создать группу (${_selected.length})',
                      loading: _creating,
                      onPressed: canCreate ? _createGroup : null,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(AlbineColors colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searchedOnce) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Найди друзей по имени пользователя,\nчтобы добавить в группу',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          'Никого не нашлось',
          style: TextStyle(color: colors.textSecondary),
        ),
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
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          title: Text(
            p.displayName,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          subtitle: Text(
            '@${p.username}',
            style: TextStyle(color: colors.textSecondary),
          ),
          trailing: Icon(Icons.add_circle_outline, color: colors.accent),
          onTap: () => _toggle(p),
        );
      },
    );
  }
}
