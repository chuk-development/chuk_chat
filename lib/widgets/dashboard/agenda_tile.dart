// Home agenda: a time column, the title and the place, and a now-line
// between what is over and what is next when the agenda is for today.

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

class AgendaTile extends StatelessWidget {
  const AgendaTile({super.key, required this.agenda, required this.now});

  final AgendaWidget agenda;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = dashboardStrings(context);
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime? date = agenda.date;
    final bool isToday = date == null || date == today;
    final bool isPast = date != null && date.isBefore(today);
    final int nowMinutes = now.hour * 60 + now.minute;

    // Where the now-line goes: before the first item that has not started.
    int? lineAt;
    if (isToday) {
      lineAt = agenda.items.length;
      for (int i = 0; i < agenda.items.length; i++) {
        final int? m = agenda.items[i].minutes;
        if (m != null && m > nowMinutes) {
          lineAt = i;
          break;
        }
      }
    }

    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < agenda.items.length; i++) {
      if (lineAt == i) rows.add(_NowLine(label: l.dashAgendaNow));
      final AgendaItem item = agenda.items[i];
      final int? m = item.minutes;
      final bool over = isPast || (isToday && m != null && m <= nowMinutes);
      final bool next = isToday && lineAt == i;
      final String? until = next && m != null
          ? l.dashInDuration(_duration(m - nowMinutes))
          : null;
      rows.add(
        _AgendaRow(
          item: item,
          over: over,
          next: next,
          last: i == agenda.items.length - 1,
          until: until,
          allDay: l.dashAgendaAllDay,
        ),
      );
    }
    if (lineAt != null &&
        lineAt == agenda.items.length &&
        agenda.items.isNotEmpty) {
      rows.add(_NowLine(label: l.dashAgendaNow));
    }

    return DashboardCard(
      widget: agenda,
      now: now,
      leading: DashboardBadge(
        icon: dashboardTypeIcon(DashboardWidgetType.agenda),
      ),
      child: agenda.items.isEmpty
          ? Text(
              l.dashAgendaEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: rows,
            ),
    );
  }
}

String _duration(int minutes) {
  final int h = minutes ~/ 60;
  final int m = minutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// One item: the time, a dot on a thin track (a capsule for the next one),
/// the title and the place.
class _AgendaRow extends StatelessWidget {
  const _AgendaRow({
    required this.item,
    required this.over,
    required this.next,
    required this.last,
    required this.until,
    required this.allDay,
  });

  final AgendaItem item;
  final bool over;
  final bool next;
  final bool last;
  final String? until;
  final String allDay;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final Color card = dashboardCardFill(theme);
    final Color accent = theme.colorScheme.primary;
    final Color accentInk = theme.accentForegroundOn(card);
    final Color ink = over ? m3.onSurfaceVariant : theme.colorScheme.onSurface;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 50,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                item.time.isEmpty ? allDay : item.time,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: next ? accentInk : m3.onSurfaceVariant,
                  height: 20 / 14,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: 22,
            child: Column(
              children: <Widget>[
                const SizedBox(height: 4),
                Container(
                  width: next ? 12 : 10,
                  height: next ? 22 : 10,
                  decoration: BoxDecoration(
                    color: next
                        ? accent
                        : (over ? m3.outlineVariant : Colors.transparent),
                    borderRadius: BorderRadius.circular(6),
                    border: next || over
                        ? null
                        : Border.all(color: m3.outline, width: 1.6),
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: m3.outlineVariant.withValues(alpha: 0.7),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 20 / 14,
                      color: ink,
                    ),
                  ),
                  if (until != null)
                    Text(
                      until!,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: accentInk,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (item.place.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          HugeIcon(
                            HugeIcons.location01,
                            size: 13,
                            color: m3.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              item.place,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: m3.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NowLine extends StatelessWidget {
  const _NowLine({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color c = theme.colorScheme.primary;
    final Color text = theme.accentForegroundOn(dashboardCardFill(theme));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 50,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: text,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          SizedBox(
            width: 22,
            child: Center(
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
            ),
          ),
          Expanded(child: Container(height: 2, color: c)),
        ],
      ),
    );
  }
}
