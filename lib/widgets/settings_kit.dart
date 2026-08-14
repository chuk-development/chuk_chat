import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// Shared building blocks for the settings-style pages.
///
/// Every settings page used to carry its own private copy of these four
/// widgets. The copies had drifted apart in padding, text size and divider
/// style, so the pages no longer looked alike. One implementation keeps them
/// in sync.

/// Small uppercase caption above a [SettingsGroupedCard].
class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(
    this.label, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(4, 20, 4, 8),
  });

  final String label;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.5,
          color: colorScheme.primary,
        ),
      ),
    );
  }
}

/// Rounded surface that groups rows, with hairline dividers between them.
class SettingsGroupedCard extends StatelessWidget {
  const SettingsGroupedCard({
    super.key,
    required this.children,
    this.dividers = true,
    this.dividerIndent = 56,
  });

  final List<Widget> children;

  /// Draw a divider between children. Off for cards whose children bring
  /// their own separation (colour swatches, toggles in a grid).
  final bool dividers;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final m3 = Theme.of(context).m3;

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (dividers && i > 0) {
        rows.add(
          Divider(
            height: 1,
            thickness: 1,
            indent: dividerIndent,
            color: m3.outlineVariant,
          ),
        );
      }
      rows.add(children[i]);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Material(
        color: m3.surfaceContainer,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }
}

/// Fixed-size leading slot so rows line up whatever their icon.
class SettingsLeadingIcon extends StatelessWidget {
  const SettingsLeadingIcon({super.key, required this.icon, this.tint});

  final IconData icon;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Center(
        child: Icon(
          icon,
          size: 22,
          color: tint ?? Theme.of(context).m3.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// One tappable line inside a [SettingsGroupedCard].
///
/// Pass either [icon] (rendered through [SettingsLeadingIcon]) or a custom
/// [leading] widget.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.icon,
    this.iconColor,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showChevron = false,
  }) : assert(icon != null || leading != null, 'give the row an icon or leading');

  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Trailing chevron for rows that open another page.
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            leading ?? SettingsLeadingIcon(icon: icon!, tint: iconColor),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hasSubtitle) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: m3.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              IconTheme.merge(
                data: IconThemeData(color: m3.onSurfaceVariant),
                child: trailing!,
              ),
            ],
            if (showChevron) ...[
              const SizedBox(width: 10),
              Icon(Icons.chevron_right, size: 20, color: m3.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
  }
}

/// Colour role of a [SettingsInfoCard].
enum SettingsInfoTone { neutral, warn, danger, success }

/// Short explanatory note under a settings group.
class SettingsInfoCard extends StatelessWidget {
  const SettingsInfoCard(
    this.text, {
    super.key,
    this.tone = SettingsInfoTone.neutral,
    this.icon,
  });

  final String text;
  final SettingsInfoTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final m3 = theme.m3;

    final Color background;
    final Color foreground;
    switch (tone) {
      case SettingsInfoTone.warn:
        background = m3.warningContainer.withValues(alpha: 0.4);
        foreground = m3.onWarningContainer;
      case SettingsInfoTone.danger:
        background = colorScheme.errorContainer.withValues(alpha: 0.4);
        foreground = colorScheme.onErrorContainer;
      case SettingsInfoTone.success:
        background = m3.successContainer.withValues(alpha: 0.4);
        foreground = m3.onSuccessContainer;
      case SettingsInfoTone.neutral:
        background = m3.surfaceContainerLow;
        foreground = m3.onSurfaceVariant;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? _defaultIcon, size: 18, color: foreground),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: foreground,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData get _defaultIcon => switch (tone) {
    SettingsInfoTone.danger => Icons.error_outline,
    SettingsInfoTone.warn => Icons.warning_amber_rounded,
    _ => Icons.info_outline,
  };
}
