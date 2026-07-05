import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/albine_theme.dart';

/// Flat light background every screen sits on. Deliberately plain — the
/// glass panels on top are where the "liquid glass" effect lives, the
/// backdrop itself should not compete with them.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return ColoredBox(color: glass.background, child: child);
  }
}

/// The core "Liquid Glass" panel: blurred backdrop, translucent white tint,
/// a brighter hairline along the top edge to fake a specular light
/// reflection, and a soft shadow — on a light background a border alone
/// doesn't read as "glass", the elevation has to come from the shadow.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.borderRadius,
    this.strong = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;

  /// Brighter, more opaque fill — used for primary interactive surfaces
  /// (buttons) so they read as glass, not as flat outlined boxes.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    final radius = borderRadius ?? BorderRadius.circular(glass.radius);

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [BoxShadow(color: glass.shadow, blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: glass.blurSigma, sigmaY: glass.blurSigma),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: strong ? glass.panelTintStrong : glass.panelTint,
              borderRadius: radius,
              border: Border.all(color: glass.panelBorder, width: 1),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [glass.highlightBorder, Colors.transparent],
                stops: const [0, 0.2],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(glass.radius * 0.7),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(glass.radius * 0.7),
          child: GlassContainer(
            padding: padding,
            borderRadius: BorderRadius.circular(glass.radius * 0.7),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({super.key, required this.title, this.actions, this.leading});

  final String title;
  final List<Widget>? actions;
  final Widget? leading;

  @override
  Size get preferredSize => const Size.fromHeight(72);

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: glass.blurSigma, sigmaY: glass.blurSigma),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 40, 16, 12),
          decoration: BoxDecoration(
            color: glass.panelTint,
            border: Border(bottom: BorderSide(color: glass.panelBorder)),
          ),
          child: Row(
            children: [
              ?leading,
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: glass.textPrimary,
                  ),
                ),
              ),
              ...?actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// A pill-shaped "Liquid Glass" button — strong blur, translucent fill, a
/// bright specular highlight arcing across the top. This is the shape used
/// throughout (main actions, icon buttons), matching the rounded glass
/// capsules/orbs of iOS 26 Liquid Glass rather than a flat filled button.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = true,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    final disabled = !loading && onPressed == null;
    final baseTint = primary ? glass.panelTintStrong : glass.panelTint;
    const height = 54.0;

    return Container(
      height: height,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height / 2),
        boxShadow: disabled
            ? null
            : [BoxShadow(color: glass.shadow, blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: glass.blurSigma, sigmaY: glass.blurSigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.rectangle,
              borderRadius: BorderRadius.circular(height / 2),
              color: disabled ? baseTint.withValues(alpha: baseTint.a * 0.5) : baseTint,
              border: Border.all(color: glass.panelBorder),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [glass.highlightBorder, Colors.transparent],
                stops: const [0, 0.5],
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: loading ? null : onPressed,
                borderRadius: BorderRadius.circular(height / 2),
                child: Center(
                  child: loading
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2.4, color: glass.textOnAccent),
                        )
                      : Text(
                          label,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: glass.textOnAccent.withValues(alpha: disabled ? 0.5 : 1),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small round "Liquid Glass" icon button — same capsule/orb treatment as
/// [GlassButton] but sized for a single icon (nav bars, FAB-style actions).
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({super.key, required this.icon, required this.onPressed, this.size = 44});

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: glass.shadow, blurRadius: 12, offset: const Offset(0, 3))],
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: glass.blurSigma, sigmaY: glass.blurSigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: glass.panelTint,
              border: Border.all(color: glass.panelBorder),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [glass.highlightBorder, Colors.transparent],
                stops: const [0, 0.6],
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onPressed,
                customBorder: const CircleBorder(),
                child: Icon(icon, size: size * 0.5, color: glass.textPrimary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled field: the label sits above the field (not as a floating
/// inline label), matching the reference layout. Optionally renders a
/// show/hide toggle for password fields instead of taking [obscureText] as
/// a fixed flag.
class GlassTextField extends StatefulWidget {
  const GlassTextField({
    super.key,
    required this.label,
    this.controller,
    this.obscureText = false,
    this.autofocus = false,
    this.keyboardType,
    this.hintText,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController? controller;
  final bool obscureText;
  final bool autofocus;
  final TextInputType? keyboardType;
  final String? hintText;
  final void Function(String)? onSubmitted;

  @override
  State<GlassTextField> createState() => _GlassTextFieldState();
}

class _GlassTextFieldState extends State<GlassTextField> {
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
        TextField(
          controller: widget.controller,
          obscureText: _obscured,
          autofocus: widget.autofocus,
          keyboardType: widget.keyboardType,
          onSubmitted: widget.onSubmitted,
          style: TextStyle(color: glass.textPrimary),
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: TextStyle(color: glass.textSecondary.withValues(alpha: 0.6)),
            filled: true,
            fillColor: glass.panelTint,
            suffixIcon: widget.obscureText
                ? IconButton(
                    icon: Icon(
                      _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: glass.textSecondary,
                    ),
                    onPressed: () => setState(() => _obscured = !_obscured),
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: glass.panelBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: glass.panelBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: glass.textPrimary),
            ),
          ),
        ),
      ],
    );
  }
}

/// The one place error/status messages get rendered — neutral, not red,
/// with a small outline icon standing in for "something needs your
/// attention" instead of color-coding it. Keeps every screen's error text
/// consistent.
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

class GlassNavItem {
  const GlassNavItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// The floating pill-shaped bottom navigation bar (Telegram-style), rendered
/// as one continuous glass capsule rather than a docked Material bottom bar.
class GlassBottomNav extends StatelessWidget {
  const GlassBottomNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<GlassNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    const height = 68.0;

    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height / 2),
        boxShadow: [BoxShadow(color: glass.shadow, blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: glass.blurSigma, sigmaY: glass.blurSigma),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(height / 2),
              color: glass.panelTintStrong,
              border: Border.all(color: glass.panelBorder),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [glass.highlightBorder, Colors.transparent],
                stops: const [0, 0.4],
              ),
            ),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => onTap(i),
                        child: _GlassNavItemContent(item: items[i], active: i == currentIndex),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassNavItemContent extends StatelessWidget {
  const _GlassNavItemContent({required this.item, required this.active});

  final GlassNavItem item;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final glass = Theme.of(context).extension<AlbineGlass>()!;
    final color = active ? glass.textPrimary : glass.textSecondary;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(item.icon, size: 22, color: color),
        const SizedBox(height: 3),
        Text(
          item.label,
          style: TextStyle(fontSize: 11, color: color, fontWeight: active ? FontWeight.w600 : null),
        ),
      ],
    );
  }
}
