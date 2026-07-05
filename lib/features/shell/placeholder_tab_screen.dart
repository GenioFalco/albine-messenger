import 'package:flutter/material.dart';

import '../../shared/widgets/glass.dart';

/// Honest placeholder for a nav tab that doesn't have a defined feature
/// behind it yet — says exactly that instead of pretending to be finished.
class PlaceholderTabScreen extends StatelessWidget {
  const PlaceholderTabScreen({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
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
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
            ),
          ),
        ),
      ),
    );
  }
}
