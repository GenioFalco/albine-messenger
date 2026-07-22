import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/albine_theme.dart';

class AlbineApp extends ConsumerWidget {
  const AlbineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'Albine Messenger',
      debugShowCheckedModeBanner: false,
      theme: buildAlbineTheme(),
      routerConfig: router,
      // The OS/browser text-size accessibility setting can otherwise blow up
      // layouts (huge text, huge boxes) in ways the glass panels aren't
      // designed to absorb. Clamp it to a sane range instead of ignoring
      // accessibility scaling entirely.
      builder: (context, child) {
        final clamped = MediaQuery.textScalerOf(
          context,
        ).clamp(minScaleFactor: 1, maxScaleFactor: 1.3);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: clamped),
          child: child!,
        );
      },
    );
  }
}
