import 'dart:ui';

import 'package:flutter/material.dart';

/// Design tokens for the "Liquid Glass" look: a flat, monochrome black
/// background with translucent frosted-glass panels and controls on top —
/// white borders, white text. The one accent color is [link], reserved for
/// tappable inline text (forgot-password, sign-up) — the standard iOS
/// convention of an otherwise-monochrome screen with blue links.
/// Kept as one ThemeExtension so every glass widget in `shared/widgets`
/// reads from a single source of truth.
class AlbineGlass extends ThemeExtension<AlbineGlass> {
  const AlbineGlass({
    required this.background,
    required this.panelTint,
    required this.panelTintStrong,
    required this.panelBorder,
    required this.highlightBorder,
    required this.blurSigma,
    required this.radius,
    required this.link,
  });

  final Color background;
  final Color panelTint;
  final Color panelTintStrong;
  final Color panelBorder;
  final Color highlightBorder;
  final double blurSigma;
  final double radius;
  final Color link;

  static const dark = AlbineGlass(
    background: Color(0xFF18181B),
    panelTint: Color(0x14FFFFFF),
    panelTintStrong: Color(0x26FFFFFF),
    panelBorder: Color(0x40FFFFFF),
    highlightBorder: Color(0x66FFFFFF),
    blurSigma: 22,
    radius: 22,
    link: Color(0xFF0A84FF),
  );

  @override
  AlbineGlass copyWith({
    Color? background,
    Color? panelTint,
    Color? panelTintStrong,
    Color? panelBorder,
    Color? highlightBorder,
    double? blurSigma,
    double? radius,
    Color? link,
  }) {
    return AlbineGlass(
      background: background ?? this.background,
      panelTint: panelTint ?? this.panelTint,
      panelTintStrong: panelTintStrong ?? this.panelTintStrong,
      panelBorder: panelBorder ?? this.panelBorder,
      highlightBorder: highlightBorder ?? this.highlightBorder,
      blurSigma: blurSigma ?? this.blurSigma,
      radius: radius ?? this.radius,
      link: link ?? this.link,
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
      blurSigma: lerpDouble(blurSigma, other.blurSigma, t)!,
      radius: lerpDouble(radius, other.radius, t)!,
      link: Color.lerp(link, other.link, t)!,
    );
  }
}

ThemeData buildAlbineTheme() {
  const glass = AlbineGlass.dark;
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: glass.background,
    colorScheme: base.colorScheme.copyWith(
      primary: Colors.white,
      secondary: Colors.white70,
      surface: glass.background,
    ),
    textTheme: base.textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
    extensions: const [glass],
  );
}
