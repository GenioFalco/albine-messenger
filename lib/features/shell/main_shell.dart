import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../chat/chat_screen.dart';
import '../conversations/conversations_screen.dart';
import '../profile/profile_screen.dart';
import 'placeholder_tab_screen.dart';

/// Below this width, the shell is a single-column, bottom-nav mobile layout.
/// At or above it, it's a 3-column layout: icon rail, list, detail — all
/// visible at once, nothing pushed as a separate route.
const _wideBreakpoint = 900.0;

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;

  static const _destinations = [
    NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Чаты'),
    NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Профиль'),
    NavigationDestination(icon: Icon(Icons.more_horiz), label: 'Ещё'),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return constraints.maxWidth >= _wideBreakpoint ? _buildWide(context) : _buildNarrow(context);
      },
    );
  }

  Widget _buildNarrow(BuildContext context) {
    const tabs = [
      ConversationsScreen(),
      ProfileScreen(),
      PlaceholderTabScreen(title: 'Ещё'),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: _destinations,
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;

    Widget content;
    switch (_index) {
      case 0:
        content = const _ChatsPane();
      case 1:
        content = const ProfileScreen();
      default:
        content = const PlaceholderTabScreen(title: 'Ещё');
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            backgroundColor: colors.background,
            destinations: _destinations
                .map((d) => NavigationRailDestination(icon: d.icon, selectedIcon: d.selectedIcon, label: Text(d.label)))
                .toList(),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: content),
        ],
      ),
    );
  }
}

class _ChatsPane extends ConsumerWidget {
  const _ChatsPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedConversationIdProvider);
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return Row(
      children: [
        SizedBox(width: 340, child: const ConversationsScreen(embedded: true)),
        const VerticalDivider(width: 1),
        Expanded(
          child: selectedId == null
              ? Center(
                  child: Text(
                    'Выбери чат слева',
                    style: TextStyle(color: colors.textSecondary),
                  ),
                )
              : ChatScreen(
                  key: ValueKey(selectedId),
                  conversationId: selectedId,
                  onBack: () => ref.read(selectedConversationIdProvider.notifier).state = null,
                ),
        ),
      ],
    );
  }
}
