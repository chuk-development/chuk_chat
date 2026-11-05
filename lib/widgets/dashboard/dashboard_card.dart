// The shell every Home widget sits in: a tonal card with 18 px corners, the
// title row, the body, and the small "by · when" footer (docs/DASHBOARD.md §2).

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// The corner of every Home card (docs/DESIGN.md §6: cards 14–18).
const double kDashboardCardRadius = 22;

/// The inner padding of a Home card.
const EdgeInsets kDashboardCardPadding = EdgeInsets.fromLTRB(18, 16, 18, 14);

/// The strings, also when a test mounts a widget without the delegate.
AppLocalizations dashboardStrings(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

/// "just now", "5 min ago", "yesterday", or a date.
String dashboardRelativeTime(AppLocalizations l, DateTime? at, DateTime now) {
  if (at == null) return '';
  final DateTime local = at.toLocal();
  final Duration d = now.difference(local);
  if (d.inMinutes < 1) return l.dashJustNow;
  if (d.inMinutes < 60) return l.dashMinAgo('${d.inMinutes}');
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(local.year, local.month, local.day);
  final int days = today.difference(day).inDays;
  if (days == 0) return l.dashHourAgo('${d.inHours}');
  if (days == 1) return l.dashYesterday;
  if (days < 7) return l.dashDaysAgo('$days');
  return '${local.day}.${local.month}.${local.year}';
}

/// The quiet card fill: a soft tonal surface, one step off the page.
Color dashboardCardFill(ThemeData theme) => theme.brightness == Brightness.dark
    ? theme.m3.surfaceContainer
    : theme.m3.surfaceContainerLow;

/// Set by the grid when a card shares its row with others: the card then
/// fills the row's height, its body at the top and its footer at the bottom.
class DashboardTileFill extends InheritedWidget {
  const DashboardTileFill({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DashboardTileFill>() != null;

  @override
  bool updateShouldNotify(DashboardTileFill oldWidget) => false;
}

/// The tonal card. [title] and [trailing] form the head row; [footer] is
/// drawn when the widget carries `by` or `updated_at`.
class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    required this.widget,
    required this.now,
    required this.child,
    this.leading,
    this.trailing,
    this.color,
    this.showTitle = true,
    this.onTap,
  });

  final DashboardWidget widget;
  final DateTime now;
  final Widget child;
  final Widget? leading;
  final Widget? trailing;

  /// The fill. Defaults to `surfaceContainer`.
  final Color? color;
  final bool showTitle;

  /// Makes the whole card a target (it springs on press).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final AppLocalizations l = dashboardStrings(context);
    final String when = dashboardRelativeTime(l, widget.updatedAt, now);
    final String footer = <String>[
      if (widget.by.isNotEmpty) widget.by,
      if (when.isNotEmpty) when,
    ].join(' · ');
    final bool fill = DashboardTileFill.of(context);
    final Color background = color ?? dashboardCardFill(theme);
    final Widget card = Container(
      decoration: BoxDecoration(
        color: onTap == null ? background : null,
        borderRadius: BorderRadius.circular(kDashboardCardRadius),
      ),
      clipBehavior: Clip.antiAlias,
      padding: kDashboardCardPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          if (showTitle)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  if (leading != null) ...<Widget>[
                    leading!,
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          if (fill)
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: child,
              ),
            )
          else
            child,
          if (footer.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                footer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: m3.onSurfaceVariant.withValues(alpha: 0.8),
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                ),
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return card;
    return MorphTap(
      onTap: onTap,
      color: background,
      pressedScale: 0.98,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDashboardCardRadius),
      ),
      child: card,
    );
  }
}

/// A HugeIcon cut out of an expressive cookie, for a card's head row.
class DashboardBadge extends StatelessWidget {
  const DashboardBadge({
    super.key,
    required this.icon,
    this.size = 30,
    this.fill,
    this.glyph,
    this.shape,
  });

  final HugeIconData icon;
  final double size;
  final Color? fill;
  final Color? glyph;

  /// Null is a quiet squircle; pass a [CookieShape] for an expressive one.
  final ShapeBorder? shape;

  @override
  Widget build(BuildContext context) {
    final MaterialYouTokens m3 = Theme.of(context).m3;
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: fill ?? m3.surfaceContainerHighest,
          shape:
              shape ??
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(size * 0.32),
              ),
        ),
        child: Center(
          child: HugeIcon(
            icon,
            size: size * 0.55,
            color: glyph ?? m3.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// The glyph for a widget type (the edit list, the empty state).
HugeIconData dashboardTypeIcon(DashboardWidgetType type) => switch (type) {
  DashboardWidgetType.tracker => HugeIcons.target01,
  DashboardWidgetType.metric => HugeIcons.chartIncrease,
  DashboardWidgetType.checklist => HugeIcons.checkList,
  DashboardWidgetType.note => HugeIcons.note01,
  DashboardWidgetType.chart => HugeIcons.chartHistogram,
  DashboardWidgetType.agenda => HugeIcons.calendar03,
  DashboardWidgetType.prompts => HugeIcons.sparkles,
  DashboardWidgetType.weather => HugeIcons.sunCloud01,
};

String dashboardTypeLabel(AppLocalizations l, DashboardWidgetType type) =>
    switch (type) {
      DashboardWidgetType.tracker => l.dashTypeTracker,
      DashboardWidgetType.metric => l.dashTypeMetric,
      DashboardWidgetType.checklist => l.dashTypeChecklist,
      DashboardWidgetType.note => l.dashTypeNote,
      DashboardWidgetType.chart => l.dashTypeChart,
      DashboardWidgetType.agenda => l.dashTypeAgenda,
      DashboardWidgetType.prompts => l.dashTypePrompts,
      DashboardWidgetType.weather => l.dashTypeWeather,
    };
