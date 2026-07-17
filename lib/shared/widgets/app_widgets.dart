import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/albine_theme.dart';

/// A small floating card (not a full-width bottom sheet) over a blurred
/// background — matches the iOS/Telegram/WhatsApp mobile context-menu look.
/// [builder] should return just the card's own content; this constrains its
/// width, positions it near the bottom, and blurs everything behind it on
/// narrow (mobile-layout) screens. On wide/desktop screens there's no blur
/// or dim at all, matching the Telegram desktop reference — just the
/// floating card over the sharp, unmodified background.
///
/// Deliberately a dialog (`showGeneralDialog`), not `showModalBottomSheet`:
/// an earlier version stretched the sheet's own hit-testable area to the
/// full screen to get a full-background blur, which — because that area now
/// covered where the framework's own "tap outside to dismiss" barrier would
/// otherwise catch the tap — broke tapping outside to close (only the
/// sheet's built-in swipe-down still worked). `barrierDismissible` on a
/// dialog gives that behavior for free, and the blur can still cover the
/// whole screen independently via the transition builder.
Future<T?> showBlurredModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 300,
  // When set (the message action sheet passes the long-pressed bubble's own
  // on-screen rect), the card floats right next to that message — below it
  // if there's room, above it otherwise — instead of always bottom-center.
  // [anchorAlignRight] should match the message's own side (true for "mine"
  // bubbles) so the card lines up with it horizontally too.
  Rect? anchorRect,
  bool anchorAlignRight = false,
}) {
  // Mirrors main_shell.dart's `_wideBreakpoint` (900) — below it we're the
  // single-column mobile layout.
  final blurred = MediaQuery.sizeOf(context).width < 900;

  return showGeneralDialog<T>(
    context: context,
    barrierLabel: 'dismiss',
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      // showModalBottomSheet wraps its content in a Material for you;
      // showGeneralDialog doesn't — without this, any ListTile/InkWell
      // inside builder() (every action sheet has one) throws "No Material
      // widget found", which a release build renders as a plain gray box
      // instead of an error message.
      final content = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Material(
          type: MaterialType.transparency,
          child: builder(dialogContext),
        ),
      );

      if (anchorRect == null) {
        return SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(padding: const EdgeInsets.all(12), child: content),
          ),
        );
      }

      final screenSize = MediaQuery.sizeOf(dialogContext);
      final viewPadding = MediaQuery.paddingOf(dialogContext);
      const gap = 8.0;
      // Rough space budget for the card — without knowing its real height
      // ahead of time (it depends on the message text + how many actions
      // apply), this is just a "does it comfortably fit below" heuristic;
      // worst case it still ends up on whichever side has more room.
      const wantsSpace = 320.0;
      final spaceBelow =
          screenSize.height - anchorRect.bottom - viewPadding.bottom - gap;
      final spaceAbove = anchorRect.top - viewPadding.top - gap;
      final showBelow = spaceBelow >= wantsSpace || spaceBelow >= spaceAbove;

      return Stack(
        children: [
          Positioned(
            top: showBelow ? anchorRect.bottom + gap : null,
            bottom: showBelow ? null : screenSize.height - anchorRect.top + gap,
            left: anchorAlignRight ? null : 12,
            right: anchorAlignRight ? 12 : null,
            child: content,
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final t = Curves.easeOut.transform(animation.value);
      // A colored/decorated box is opaque to hit-testing over its *entire*
      // area even where nothing else is painted — wrapping the dim/blur
      // veil around the card (as an earlier version did) meant every tap,
      // including ones meant to reach the barrier below and dismiss the
      // sheet, was swallowed by this veil instead. Making it an explicit
      // sibling (via Stack) with its own tap-to-dismiss handler fixes that:
      // the card, painted after it, still gets first claim on its own area.
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: blurred
                  ? BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 6 * t, sigmaY: 6 * t),
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.12 * t),
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
          Opacity(
            opacity: t,
            child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
          ),
        ],
      );
    },
  );
}

/// Plain background every screen sits on.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return ColoredBox(color: colors.background, child: child);
  }
}

/// A plain card used to visually group form fields.
class FormPanel extends StatelessWidget {
  const FormPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(colors.radius),
        border: Border.all(color: colors.border),
      ),
      child: child,
    );
  }
}

/// A plain, tappable list row (avatar/title/subtitle, settings row, etc).
class AppCard extends StatelessWidget {
  const AppCard({
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
  /// list pane.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final radius = BorderRadius.circular(colors.radius * 0.7);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: highlighted ? colors.surfaceStrong : colors.surface,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A normal, solid, full-width rounded-rectangle button.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;

    return SizedBox(
      height: 50,
      width: double.infinity,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.textOnAccent,
          disabledBackgroundColor: colors.accent.withValues(alpha: 0.4),
          disabledForegroundColor: colors.textOnAccent.withValues(alpha: 0.7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(colors.radius),
          ),
          elevation: 0,
        ),
        child: loading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: colors.textOnAccent,
                ),
              )
            : Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// A small round icon button on a light circular background.
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 40,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: colors.surface,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: Icon(icon, size: size * 0.5, color: colors.textPrimary),
        ),
      ),
    );
  }
}

/// A labelled field: the label sits above a normal [TextField].
class LabeledField extends StatefulWidget {
  const LabeledField({
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
  State<LabeledField> createState() => _LabeledFieldState();
}

class _LabeledFieldState extends State<LabeledField> {
  late bool _obscured = widget.obscureText;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            widget.label,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
        ),
        TextField(
          controller: widget.controller,
          obscureText: _obscured,
          autofocus: widget.autofocus,
          keyboardType: widget.keyboardType,
          onSubmitted: widget.onSubmitted,
          style: TextStyle(color: colors.textPrimary),
          decoration: InputDecoration(
            hintText: widget.hintText,
            filled: true,
            fillColor: colors.surface,
            suffixIcon: widget.obscureText
                ? IconButton(
                    icon: Icon(
                      _obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      color: colors.textSecondary,
                    ),
                    onPressed: () => setState(() => _obscured = !_obscured),
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(colors.radius * 0.7),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(colors.radius * 0.7),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(colors.radius * 0.7),
              borderSide: BorderSide(color: colors.accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// The one place error/status messages get rendered.
class AppErrorText extends StatelessWidget {
  const AppErrorText(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            Icons.info_outline,
            size: 16,
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: colors.textPrimary, height: 1.3),
          ),
        ),
      ],
    );
  }
}

/// A single row in an iOS-style blurred action sheet (see
/// [showBlurredModalSheet]) — icon + label, optionally red for a
/// destructive action. Used by the message and conversation action sheets.
class ActionSheetTile extends StatelessWidget {
  const ActionSheetTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    final color = destructive ? Colors.red : colors.textPrimary;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }
}

/// The single accent-colored, tappable inline text used across auth
/// screens ("Забыли пароль?", "Зарегистрироваться", ...).
class AppLink extends StatelessWidget {
  const AppLink({super.key, required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AlbineColors>()!;
    return InkWell(
      onTap: onTap,
      child: Text(
        text,
        style: TextStyle(color: colors.accent, fontWeight: FontWeight.w500),
      ),
    );
  }
}
