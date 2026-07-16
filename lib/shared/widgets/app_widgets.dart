import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/theme/albine_theme.dart';

/// A bottom sheet whose entire background (not just the area behind the
/// sheet card) is blurred, matching the iOS/Telegram/WhatsApp context-menu
/// look — `showModalBottomSheet` alone only dims with a flat scrim.
/// [builder] should return just the sheet's own content (a rounded card);
/// this wraps it with the full-screen blur and bottom alignment.
Future<T?> showBlurredModalSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.2),
    builder: (sheetContext) {
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: SizedBox(
            width: double.infinity,
            height: MediaQuery.of(sheetContext).size.height,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: builder(sheetContext),
            ),
          ),
        ),
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
