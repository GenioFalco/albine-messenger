import 'package:flutter/material.dart';

import '../../core/theme/albine_theme.dart';

/// Honest placeholder for a nav tab that doesn't have a defined feature
/// behind it yet — says exactly that instead of pretending to be finished.
class PlaceholderTabScreen extends StatelessWidget {
  const PlaceholderTabScreen({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Пока не решили, что здесь будет 🤔',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
      ),
    );
  }
}
