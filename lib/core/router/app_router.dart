import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/session_controller.dart';
import '../../features/auth/auth_screen.dart';
import '../../features/chat/chat_screen.dart';
import '../../features/onboarding/profile_setup_screen.dart';
import '../../features/onboarding/unlock_screen.dart';
import '../../features/shell/main_shell.dart';
import '../../features/splash/splash_screen.dart';

class _RouterRefreshNotifier extends ChangeNotifier {
  _RouterRefreshNotifier(Ref ref) {
    ref.listen(sessionControllerProvider, (previous, next) => notifyListeners());
  }
}

final goRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = _RouterRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refreshNotifier,
    redirect: (context, state) => _redirect(ref, state.matchedLocation),
    routes: [
      GoRoute(path: '/', builder: (context, state) => const SplashScreen()),
      GoRoute(path: '/auth', builder: (context, state) => const AuthScreen()),
      GoRoute(
        path: '/setup-profile',
        builder: (context, state) => const ProfileSetupScreen(),
      ),
      GoRoute(path: '/unlock', builder: (context, state) => const UnlockScreen()),
      GoRoute(
        path: '/chats',
        builder: (context, state) => const MainShell(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => ChatScreen(conversationId: state.pathParameters['id']!),
          ),
        ],
      ),
    ],
  );
});

String? _redirect(Ref ref, String location) {
  final session = ref.read(sessionControllerProvider);
  const gateRoutes = {'/auth', '/setup-profile', '/unlock'};

  switch (session.status) {
    case SessionStatus.loading:
      return null;
    case SessionStatus.signedOut:
      return location == '/auth' ? null : '/auth';
    case SessionStatus.needsProfileSetup:
      return location == '/setup-profile' ? null : '/setup-profile';
    case SessionStatus.needsPassword:
      return location == '/unlock' ? null : '/unlock';
    case SessionStatus.ready:
      if (location == '/' || gateRoutes.contains(location)) {
        return '/chats';
      }
      return null;
  }
}
