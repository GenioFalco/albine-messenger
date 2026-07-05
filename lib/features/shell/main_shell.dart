import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/albine_theme.dart';
import '../../data/providers.dart';
import '../chat/chat_screen.dart';
import '../conversations/conversations_screen.dart';
import '../profile/profile_screen.dart';
import '../../shared/widgets/glass.dart';
import 'placeholder_tab_screen.dart';

/// Below this width, the shell is a single-column, bottom-nav mobile layout.
/// At or above it, it's Element's 3-column layout: icon rail, list, detail —
/// all visible at once, nothing pushed as a separate route.
const _wideBreakpoint = 900.0;

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _index = 0;

  static const _icons = [Icons.chat_bubble_outline, Icons.person_outline, Icons.more_horiz];
  static const _labels = ['Чаты', 'Профиль', 'Ещё'];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return constraints.maxWidth >= _wideBreakpoint ? _buildWide(context) : _buildNarrow(context);
      },
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    const tabs = [
      ConversationsScreen(),
      ProfileScreen(),
      PlaceholderTabScreen(title: 'Ещё'),
    ];

    return Scaffold(
      backgroundColor: glass.background,
      body: Stack(
        children: [
          IndexedStack(index: _index, children: tabs),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: GlassTabBar.bottom(
                tabs: [
                  for (var i = 0; i < _icons.length; i++)
                    GlassTab(icon: Icon(_icons[i]), label: _labels[i]),
                ],
                selectedIndex: _index,
                onTabSelected: (i) => setState(() => _index = i),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;

    Widget content;
    switch (_index) {
      case 0:
        content = _ChatsPane(glass: glass);
      case 1:
        content = const ProfileScreen();
      default:
        content = const PlaceholderTabScreen(title: 'Ещё');
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackdrop(
        child: Row(
          children: [
            _SidebarRail(
              icons: _icons,
              labels: _labels,
              index: _index,
              onChanged: (i) => setState(() => _index = i),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

class _ChatsPane extends ConsumerWidget {
  const _ChatsPane({required this.glass});

  final AlbineGlass glass;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedId = ref.watch(selectedConversationIdProvider);
    return Row(
      children: [
        SizedBox(width: 340, child: const ConversationsScreen(embedded: true)),
        const VerticalDivider(width: 1),
        Expanded(
          child: selectedId == null
              ? Center(
                  child: Text(
                    'Выбери чат слева',
                    style: TextStyle(color: glass.textSecondary),
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

class _SidebarRail extends StatelessWidget {
  const _SidebarRail({
    required this.icons,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<IconData> icons;
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return SizedBox(
      width: 88,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              for (var i = 0; i < icons.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: GlassIconButton(
                    icon: Icon(icons[i], color: i == index ? glass.textPrimary : glass.textSecondary),
                    size: 52,
                    onPressed: () => onChanged(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
