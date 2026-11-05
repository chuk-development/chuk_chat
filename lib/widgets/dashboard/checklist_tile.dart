// Home checklist: a tap ticks an item through a `check` op; the tick springs
// in and the text strikes through.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/dashboard/dashboard_controller.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

class ChecklistTile extends StatelessWidget {
  const ChecklistTile({
    super.key,
    required this.checklist,
    required this.controller,
    required this.now,
  });

  final ChecklistWidget checklist;
  final DashboardController controller;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = dashboardStrings(context);
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final int total = checklist.items.length;
    final int done = checklist.doneCount;
    final bool all = total > 0 && done == total;
    return DashboardCard(
      widget: checklist,
      now: now,
      trailing: total == 0
          ? null
          : DecoratedBox(
              decoration: ShapeDecoration(
                color: all ? m3.successContainer : m3.surfaceContainerHighest,
                shape: const StadiumBorder(),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Text(
                  l.dashChecklistCount('$done', '$total'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: all ? m3.onSuccessContainer : m3.onSurfaceVariant,
                  ),
                ),
              ),
            ),
      child: total == 0
          ? Text(
              l.dashChecklistEmpty,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: m3.onSurfaceVariant,
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final ChecklistItem item in checklist.items)
                  _ItemRow(
                    key: ValueKey<String>('check-${checklist.id}-${item.id}'),
                    item: item,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      controller.check(checklist.id, item.id, !item.done);
                    },
                  ),
              ],
            ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({super.key, required this.item, required this.onTap});

  final ChecklistItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final Color fill = theme.colorScheme.primary;
    return Semantics(
      checked: item.done,
      label: item.text,
      child: MorphTap(
        onTap: onTap,
        pressedScale: 0.97,
        pressedColor: m3.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // One text line high, so the box sits on the first line.
            SizedBox(
              height: 22,
              child: Center(
                child: AnimatedContainer(
                  duration: kExpressiveShort,
                  curve: kExpressiveDecelerate,
                  width: 22,
                  height: 22,
                  decoration: ShapeDecoration(
                    color: item.done ? fill : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                      side: item.done
                          ? BorderSide.none
                          : BorderSide(color: m3.outline, width: 2),
                    ),
                  ),
                  child: AnimatedScale(
                    scale: item.done ? 1 : 0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutBack,
                    child: Center(
                      child: HugeIcon(
                        HugeIcons.tick02,
                        size: 16,
                        color: readableOnFill(
                          fill,
                          theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: kExpressiveShort,
                style: (theme.textTheme.bodyMedium ?? const TextStyle())
                    .copyWith(
                      height: 22 / 14,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: item.done
                          ? m3.onSurfaceVariant
                          : theme.colorScheme.onSurface,
                      decoration: item.done ? TextDecoration.lineThrough : null,
                      decorationColor: m3.onSurfaceVariant,
                    ),
                child: Text(item.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
