import 'package:flutter/material.dart';

/// Plain, ordinary design tokens — no glass, no gradients, no blur. A clean
/// light theme like Telegram/Element: white surfaces, one blue accent,
/// normal rounded-rectangle buttons and cards.
class AlbineColors extends ThemeExtension<AlbineColors> {
  const AlbineColors({
    required this.background,
    required this.surface,
    required this.surfaceStrong,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.accent,
    required this.textOnAccent,
    required this.radius,
  });

  final Color background;
  final Color surface;
  final Color surfaceStrong;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color accent;
  final Color textOnAccent;
  final double radius;

  static const light = AlbineColors(
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFF3F4F6),
    surfaceStrong: Color(0xFFE9EBEF),
    border: Color(0xFFECEEF1),
    textPrimary: Color(0xFF15181D),
    textSecondary: Color(0xFF8A9099),
    accent: Color(0xFF2F6BFF),
    textOnAccent: Color(0xFFFFFFFF),
    radius: 20,
  );

  @override
  AlbineColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceStrong,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? accent,
    Color? textOnAccent,
    double? radius,
  }) {
    return AlbineColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceStrong: surfaceStrong ?? this.surfaceStrong,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      accent: accent ?? this.accent,
      textOnAccent: textOnAccent ?? this.textOnAccent,
      radius: radius ?? this.radius,
    );
  }

  @override
  AlbineColors lerp(ThemeExtension<AlbineColors>? other, double t) {
    if (other is! AlbineColors) return this;
    return AlbineColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceStrong: Color.lerp(surfaceStrong, other.surfaceStrong, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      textOnAccent: Color.lerp(textOnAccent, other.textOnAccent, t)!,
      radius: radius,
    );
  }
}

ThemeData buildAlbineTheme() {
  const colors = AlbineColors.light;
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: colors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: colors.accent,
      onPrimary: colors.textOnAccent,
      secondary: colors.textSecondary,
      surface: colors.background,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: colors.textPrimary,
      displayColor: colors.textPrimary,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.background,
      foregroundColor: colors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: colors.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerColor: colors.border,
    extensions: const [colors],
  );
}
