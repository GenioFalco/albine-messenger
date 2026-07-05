import 'package:flutter/material.dart';

import '../../shared/widgets/glass.dart';
import '../conversations/conversations_screen.dart';
import '../profile/profile_screen.dart';
import 'placeholder_tab_screen.dart';

/// Telegram-style shell: tab bodies underneath, one floating glass capsule
/// nav bar always on top. Only the root `/chats` route uses this — an open
/// conversation (`/chats/:id`) is a separate full-screen route without it.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  static const _tabs = [
    ConversationsScreen(),
    ProfileScreen(),
    PlaceholderTabScreen(title: 'Ещё'),
  ];

  static const _items = [
    GlassNavItem(icon: Icons.chat_bubble_outline, label: 'Чаты'),
    GlassNavItem(icon: Icons.person_outline, label: 'Профиль'),
    GlassNavItem(icon: Icons.more_horiz, label: 'Ещё'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          IndexedStack(index: _index, children: _tabs),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: GlassBottomNav(
                items: _items,
                currentIndex: _index,
                onTap: (i) => setState(() => _index = i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
