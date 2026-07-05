import 'dart:ui';

import 'package:flutter/material.dart';

/// Design tokens for the "Liquid Glass" look: a light, airy background with
/// translucent frosted-glass panels and controls on top — soft shadows
/// instead of a stark border, dark text. The one accent color is [link],
/// reserved for tappable inline text (forgot-password, sign-up) — the
/// standard iOS convention of an otherwise-neutral screen with blue links.
/// Kept as one ThemeExtension so every glass widget in `shared/widgets` and
/// every screen reads colors from here instead of hardcoding black/white —
/// that's what makes switching the whole app between light/dark a token
/// change instead of a file-by-file hunt.
class AlbineGlass extends ThemeExtension<AlbineGlass> {
  const AlbineGlass({
    required this.background,
    required this.panelTint,
    required this.panelTintStrong,
    required this.panelBorder,
    required this.highlightBorder,
    required this.shadow,
    required this.blurSigma,
    required this.radius,
    required this.link,
    required this.textPrimary,
    required this.textSecondary,
    required this.textOnAccent,
  });

  final Color background;
  final Color panelTint;
  final Color panelTintStrong;
  final Color panelBorder;
  final Color highlightBorder;
  final Color shadow;
  final double blurSigma;
  final double radius;
  final Color link;

  /// Main body/heading text color.
  final Color textPrimary;

  /// Secondary/hint/subtitle text color.
  final Color textSecondary;

  /// Text color for content sitting on a filled/strong glass surface
  /// (primary buttons, "my message" bubbles).
  final Color textOnAccent;

  static const light = AlbineGlass(
    background: Color(0xFFEDEDF2),
    panelTint: Color(0xE6FFFFFF),
    panelTintStrong: Color(0xF5FFFFFF),
    panelBorder: Color(0x14000000),
    highlightBorder: Color(0xB3FFFFFF),
    shadow: Color(0x14000000),
    blurSigma: 22,
    radius: 22,
    link: Color(0xFF0A84FF),
    textPrimary: Color(0xFF1C1C1E),
    textSecondary: Color(0xFF6E6E73),
    textOnAccent: Color(0xFF1C1C1E),
  );

  @override
  AlbineGlass copyWith({
    Color? background,
    Color? panelTint,
    Color? panelTintStrong,
    Color? panelBorder,
    Color? highlightBorder,
    Color? shadow,
    double? blurSigma,
    double? radius,
    Color? link,
    Color? textPrimary,
    Color? textSecondary,
    Color? textOnAccent,
  }) {
    return AlbineGlass(
      background: background ?? this.background,
      panelTint: panelTint ?? this.panelTint,
      panelTintStrong: panelTintStrong ?? this.panelTintStrong,
      panelBorder: panelBorder ?? this.panelBorder,
      highlightBorder: highlightBorder ?? this.highlightBorder,
      shadow: shadow ?? this.shadow,
      blurSigma: blurSigma ?? this.blurSigma,
      radius: radius ?? this.radius,
      link: link ?? this.link,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textOnAccent: textOnAccent ?? this.textOnAccent,
    );
  }

  @override
  AlbineGlass lerp(ThemeExtension<AlbineGlass>? other, double t) {
    if (other is! AlbineGlass) return this;
    return AlbineGlass(
      background: Color.lerp(background, other.background, t)!,
      panelTint: Color.lerp(panelTint, other.panelTint, t)!,
      panelTintStrong: Color.lerp(panelTintStrong, other.panelTintStrong, t)!,
      panelBorder: Color.lerp(panelBorder, other.panelBorder, t)!,
      highlightBorder: Color.lerp(highlightBorder, other.highlightBorder, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      blurSigma: lerpDouble(blurSigma, other.blurSigma, t)!,
      radius: lerpDouble(radius, other.radius, t)!,
      link: Color.lerp(link, other.link, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textOnAccent: Color.lerp(textOnAccent, other.textOnAccent, t)!,
    );
  }
}

ThemeData buildAlbineTheme() {
  const glass = AlbineGlass.light;
  final base = ThemeData.light(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: glass.background,
    colorScheme: base.colorScheme.copyWith(
      primary: glass.textPrimary,
      secondary: glass.textSecondary,
      surface: glass.background,
    ),
    textTheme: base.textTheme.apply(bodyColor: glass.textPrimary, displayColor: glass.textPrimary),
    extensions: const [glass],
  );
}
