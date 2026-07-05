import 'package:flutter/material.dart';

import '../../shared/widgets/glass.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GlassBackdrop(
        child: Center(
          child: GlassContainer(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Albine Messenger'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
