import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/humanize_error.dart';
import '../../core/pick_image.dart';
import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../../data/session_controller.dart';
import '../../domain/models.dart';
import '../../shared/widgets/app_widgets.dart';
import 'contact_profile_screen.dart';
import 'media_gallery_grid.dart';

/// Group management screen: rename (owner only), member list with a
/// "Создатель" badge on the owner and a remove action (owner only, never on
/// self), adding new members (owner only), and the group's shared media.
///
/// No per-member roles beyond owner-vs-not yet — deliberately deferred (see
/// `GroupMember.isOwner`'s doc comment) until there's an actual need for
/// finer-grained permissions.
class GroupInfoScreen extends ConsumerStatefulWidget {
  const GroupInfoScreen({
    super.key,
    required this.conversationId,
    required this.initialTitle,
    this.initialAvatarUrl,
  });

  final String conversationId;
  final String initialTitle;
  final String? initialAvatarUrl;

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  late String _title = widget.initialTitle;
  late String? _avatarUrl = widget.initialAvatarUrl;
  bool _uploadingAvatar = false;
  Future<List<GroupMember>>? _membersFuture;

  @override
  void initState() {
    super.initState();
    _refreshMembers();
  }

  void _refreshMembers() {
    final chat = ref.read(chatRepositoryProvider);
    setState(
      () => _membersFuture = chat?.fetchGroupMembers(widget.conversationId),
    );
  }

  Future<void> _changeAvatar() async {
    final picked = await pickImageBytes();
    if (picked == null || !mounted) return;
    setState(() => _uploadingAvatar = true);
    try {
      final url = await ref
          .read(chatRepositoryProvider)!
          .uploadGroupAvatar(
            conversationId: widget.conversationId,
            bytes: picked.bytes,
            mime: picked.mime,
          );
      if (mounted) setState(() => _avatarUrl = url);
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

  Future<void> _renameGroup() async {
    final controller = TextEditingController(text: _title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Название группы'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty || newTitle == _title) return;
    final chat = ref.read(chatRepositoryProvider);
    try {
      await chat?.updateGroupTitle(widget.conversationId, newTitle);
      if (mounted) setState(() => _title = newTitle);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось переименовать: ${humanizeError(e)}'),
          ),
        );
      }
    }
  }

  Future<void> _addMembers(List<GroupMember> current) async {
    final chat = ref.read(chatRepositoryProvider);
    if (chat == null) return;
    final excludeIds = current.map((m) => m.profile.id).toSet();
    final added = await showModalBottomSheet<List<AppProfile>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _AddMembersSheet(excludeIds: excludeIds),
    );
    if (added == null || added.isEmpty || !mounted) return;
    try {
      for (final profile in added) {
        await chat.addGroupMember(widget.conversationId, profile);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось добавить: ${humanizeError(e)}')),
        );
      }
    }
    _refreshMembers();
  }

  Future<void> _removeMember(GroupMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить участника?'),
        content: Text(
          '${member.profile.displayName} будет удалён(а) из группы.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Удалить', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final chat = ref.read(chatRepositoryProvider);
    try {
      await chat?.removeGroupMember(widget.conversationId, member.profile.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось удалить: ${humanizeError(e)}')),
        );
      }
    }
    _refreshMembers();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final myId = ref.watch(sessionControllerProvider).profile?.id;
    final chat = ref.watch(chatRepositoryProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Группа')),
      body: FutureBuilder<List<GroupMember>>(
        future: _membersFuture,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          final members = snapshot.data ?? const <GroupMember>[];
          final isOwner = members.any((m) => m.profile.id == myId && m.isOwner);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              FormPanel(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: (isOwner && !_uploadingAvatar)
                          ? _changeAvatar
                          : null,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CircleAvatar(
                            radius: 40,
                            backgroundColor: colors.surfaceStrong,
                            backgroundImage: _avatarUrl != null
                                ? NetworkImage(_avatarUrl!)
                                : null,
                            child: _avatarUrl != null
                                ? null
                                : Text(
                                    _title.isNotEmpty
                                        ? _title[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                      fontSize: 30,
                                      color: colors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                          if (_uploadingAvatar)
                            const CircularProgressIndicator(strokeWidth: 2)
                          else if (isOwner)
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
                    InkWell(
                      onTap: isOwner ? _renameGroup : null,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _title,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            if (isOwner) ...[
                              const SizedBox(width: 6),
                              Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: colors.textSecondary,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${members.length} участников',
                      style: TextStyle(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Участники',
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (isOwner)
                      TextButton.icon(
                        onPressed: () => _addMembers(members),
                        icon: const Icon(Icons.person_add_alt_1, size: 18),
                        label: const Text('Добавить'),
                      ),
                  ],
                ),
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                FormPanel(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final member in members)
                        ListTile(
                          leading: CircleAvatar(
                            backgroundColor: colors.surfaceStrong,
                            backgroundImage: member.profile.avatarUrl != null
                                ? NetworkImage(member.profile.avatarUrl!)
                                : null,
                            child: member.profile.avatarUrl != null
                                ? null
                                : Text(
                                    member.profile.displayName.isNotEmpty
                                        ? member.profile.displayName[0]
                                              .toUpperCase()
                                        : '?',
                                    style: TextStyle(
                                      color: colors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                          title: Text(member.profile.displayName),
                          subtitle: Text(
                            member.isOwner
                                ? 'Создатель группы'
                                : '@${member.profile.username}',
                            style: member.isOwner
                                ? TextStyle(
                                    color: colors.accent,
                                    fontWeight: FontWeight.w600,
                                  )
                                : null,
                          ),
                          trailing: (isOwner && member.profile.id != myId)
                              ? IconButton(
                                  icon: const Icon(
                                    Icons.remove_circle_outline,
                                    color: Colors.red,
                                  ),
                                  onPressed: () => _removeMember(member),
                                )
                              : null,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  ContactProfileScreen(peer: member.profile),
                            ),
                          ),
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
                    conversationId: widget.conversationId,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Search + multi-select sheet for adding members to an *existing* group —
/// mirrors `new_group_sheet.dart`'s search UI, but returns the picked
/// profiles instead of creating a new conversation, and has no title field.
class _AddMembersSheet extends ConsumerStatefulWidget {
  const _AddMembersSheet({required this.excludeIds});

  final Set<String> excludeIds;

  @override
  ConsumerState<_AddMembersSheet> createState() => _AddMembersSheetState();
}

class _AddMembersSheetState extends ConsumerState<_AddMembersSheet> {
  final _searchController = TextEditingController();
  List<AppProfile> _results = [];
  final Map<String, AppProfile> _selected = {};
  bool _loading = false;
  bool _searchedOnce = false;
  int _requestId = 0;

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
      });
      return;
    }

    setState(() => _loading = true);
    final results = await ref
        .read(profileRepositoryProvider)
        .searchProfiles(trimmed, excludeUserId: myId);
    if (reqId != _requestId) return;
    setState(() {
      _results = results
          .where(
            (p) =>
                !_selected.containsKey(p.id) &&
                !widget.excludeIds.contains(p.id),
          )
          .toList();
      _loading = false;
      _searchedOnce = true;
    });
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

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Добавить участников',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_selected.isNotEmpty) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final m in _selected.values)
                          Chip(
                            label: Text(m.displayName),
                            onDeleted: () => _toggle(m),
                            backgroundColor: colors.surfaceStrong,
                            side: BorderSide.none,
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _searchController,
                    onChanged: _search,
                    autofocus: true,
                    style: TextStyle(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Поиск',
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
                child: AppButton(
                  label: 'Добавить (${_selected.length})',
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(
                          context,
                        ).pop(_selected.values.toList()),
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
            'Найди друзей по имени пользователя',
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
