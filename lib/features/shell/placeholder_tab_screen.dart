import 'package:flutter/material.dart';

import '../../core/theme/albine_theme.dart';
import '../../shared/widgets/glass.dart';

/// Honest placeholder for a nav tab that doesn't have a defined feature
/// behind it yet — says exactly that instead of pretending to be finished.
class PlaceholderTabScreen extends StatelessWidget {
  const PlaceholderTabScreen({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(title: title),
      body: GlassBackdrop(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'Пока не решили, что здесь будет 🤔',
              textAlign: TextAlign.center,
              style: TextStyle(color: glass.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
