import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/theme/albine_theme.dart';

// Real shader-based glass — controls (buttons, icon buttons, text fields,
// nav bars) come straight from `liquid_glass_widgets`, which renders an
// actual refraction/blur shader (Impeller on iOS/Android/desktop, a
// lightweight Skia shader on web) instead of an approximated gradient.
// Re-exported here so screens only need one import.
export 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show
        GlassButton,
        GlassIconButton,
        GlassTextField,
        GlassAppBar,
        GlassContainer,
        GlassTabBar,
        GlassTab,
        GlassScaffold;

/// Flat light background every screen sits on. Deliberately plain — glass
/// belongs on individual controls, not the page background (per
/// liquid_glass_widgets' own guidance: "glass effects belong on the
/// individual interactive elements — not the bar/page surface itself").
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return ColoredBox(color: glass.background, child: child);
  }
}

/// A plain (non-liquid-glass) card used to visually group form fields —
/// intentionally NOT a glass surface. `liquid_glass_widgets` explicitly warns
/// against nesting glass controls inside a `GlassContainer`: it flips
/// `avoidsRefraction` for the whole subtree, degrading every control inside.
/// This gives the same "grouped panel" look via a soft shadow instead.
class FormPanel extends StatelessWidget {
  const FormPanel({super.key, required this.child, this.padding = const EdgeInsets.all(24)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: glass.panelTint,
        borderRadius: BorderRadius.circular(glass.radius),
        boxShadow: [BoxShadow(color: glass.shadow, blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: child,
    );
  }
}

/// A plain grouped list row (avatar/title/subtitle) — content, not a glass
/// control, so it stays outside the glass layer entirely.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.highlighted = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  /// True for the currently-selected row in the desktop 3-column layout's
  /// list pane (there's no route change to signal selection there, so the
  /// row itself needs to show it).
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    final radius = BorderRadius.circular(glass.radius * 0.7);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: highlighted ? glass.panelTintStrong : glass.panelTint,
        borderRadius: radius,
        elevation: 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A labelled field: the label sits above a real shader-backed
/// [GlassTextField], with a self-contained show/hide toggle for password
/// fields (the package field takes a fixed [obscureText] flag, not a
/// built-in toggle).
class LabeledGlassField extends StatefulWidget {
  const LabeledGlassField({
    super.key,
    required this.label,
    this.controller,
    this.obscureText = false,
    this.autofocus = false,
    this.keyboardType,
    this.placeholder,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController? controller;
  final bool obscureText;
  final bool autofocus;
  final TextInputType? keyboardType;
  final String? placeholder;
  final void Function(String)? onSubmitted;

  @override
  State<LabeledGlassField> createState() => _LabeledGlassFieldState();
}

class _LabeledGlassFieldState extends State<LabeledGlassField> {
  late bool _obscured = widget.obscureText;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(widget.label, style: TextStyle(color: glass.textSecondary)),
        ),
        GlassTextField(
          controller: widget.controller,
          obscureText: _obscured,
          autofocus: widget.autofocus,
          keyboardType: widget.keyboardType,
          placeholder: widget.placeholder,
          onSubmitted: widget.onSubmitted,
          suffixIcon: widget.obscureText
              ? Icon(
                  _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  size: 20,
                  color: glass.textSecondary,
                )
              : null,
          onSuffixTap: widget.obscureText ? () => setState(() => _obscured = !_obscured) : null,
        ),
      ],
    );
  }
}

/// The one place error/status messages get rendered — neutral, not red,
/// with a small outline icon standing in for "something needs your
/// attention" instead of color-coding it.
class GlassErrorText extends StatelessWidget {
  const GlassErrorText(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.info_outline, size: 16, color: glass.textSecondary),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: TextStyle(color: glass.textPrimary, height: 1.3)),
        ),
      ],
    );
  }
}

/// The single accent-colored, tappable inline text used across auth
/// screens ("Забыли пароль?", "Зарегистрироваться", ...).
class GlassLink extends StatelessWidget {
  const GlassLink({super.key, required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return InkWell(
      onTap: onTap,
      child: Text(text, style: TextStyle(color: glass.link, fontWeight: FontWeight.w500)),
    );
  }
}
