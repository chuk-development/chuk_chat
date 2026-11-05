import 'dart:async';
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:chuk_chat/constants.dart' show kRadiusDialog;
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/main_agent_launcher.dart';
import 'package:chuk_chat/services/dashboard/dashboard_controller.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/shapes.dart';
import 'package:chuk_chat/ui/expressive/staggered.dart';
import 'package:chuk_chat/ui/expressive/top_veil.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/dashboard/agenda_tile.dart';
import 'package:chuk_chat/widgets/dashboard/chart_tile.dart';
import 'package:chuk_chat/widgets/dashboard/checklist_tile.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';
import 'package:chuk_chat/widgets/dashboard/metric_tile.dart';
import 'package:chuk_chat/widgets/dashboard/note_tile.dart';
import 'package:chuk_chat/widgets/dashboard/prompts_tile.dart';
import 'package:chuk_chat/widgets/dashboard/tracker_tile.dart';
import 'package:chuk_chat/widgets/dashboard/weather_tile.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// The room the shell's floating Home | Agents switch takes above the
/// content, under the status bar.
const double kDashboardTopChrome = 64;

/// From this width on, Home lays out four columns instead of two.
const double kDashboardWideBreakpoint = 720;

const double _kGap = 12;
const double _kSide = 16;

/// Packs [widgets] into rows of [columns] columns, in order. A half widget
/// takes one column; a full one takes the whole row on a phone and two of
/// four on a wide window. A widget that does not fit the rest of a row starts
/// the next one.
List<List<DashboardWidget>> packDashboardRows(
  List<DashboardWidget> widgets,
  int columns,
) {
  final List<List<DashboardWidget>> rows = <List<DashboardWidget>>[];
  List<DashboardWidget> row = <DashboardWidget>[];
  int used = 0;
  for (final DashboardWidget w in widgets) {
    final int span = dashboardSpan(w, columns);
    if (used + span > columns && row.isNotEmpty) {
      rows.add(row);
      row = <DashboardWidget>[];
      used = 0;
    }
    row.add(w);
    used += span;
  }
  if (row.isNotEmpty) rows.add(row);
  return rows;
}

int dashboardSpan(DashboardWidget w, int columns) =>
    w.size == DashboardSize.half ? 1 : (columns >= 4 ? 2 : columns);

/// Home: the dashboard the agents build (docs/DASHBOARD.md).
///
/// It draws no app bar of its own: the shell floats the Home | Agents switch
/// over it, and the content scrolls up behind the top veil. A floating
/// "Ask … anything" pill sits at the bottom.
class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    this.controller,
    this.clock,
    this.assistantName,
    this.topChrome = kDashboardTopChrome,
    this.showAskPill = true,
    this.bottomChrome,
  });

  /// Test seam; the app uses [DashboardController.instance].
  final DashboardController? controller;

  /// Test seam for the greeting and the relative times.
  final DateTime Function()? clock;

  /// The main agent's name for the ask pill; null says "your assistant".
  final String? assistantName;

  /// The room the shell's chrome takes above the content, under the status
  /// bar. The phone's top bar (switch and title strip) is taller than the
  /// desktop's floating switch.
  final double topChrome;

  /// Draws the ask pill at the bottom. The phone shell puts a composer there
  /// instead, so it turns the pill off.
  final bool showAskPill;

  /// The room kept free under the last card, above the bottom inset. Null
  /// keeps the ask pill's room.
  final double? bottomChrome;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

/// The room the ask pill takes at the bottom, so the last card scrolls
/// above it.
const double _kAskPillSpace = 84;

class _DashboardPageState extends State<DashboardPage> {
  late final DashboardController _controller =
      widget.controller ?? DashboardController.instance;
  bool _editing = false;
  Timer? _tick;

  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _controller.init();
    _controller.notice.addListener(_showNotice);
    // The greeting, the now-line and "5 min ago" move with the clock.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _showNotice());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _controller.notice.removeListener(_showNotice);
    super.dispose();
  }

  void _showNotice() {
    final String? message = _controller.notice.value;
    if (message == null || !mounted) return;
    if (ScaffoldMessenger.maybeOf(context) == null) return;
    _controller.clearNotice();
    AppNotifications.error(context, message);
  }

  Future<void> _refresh() async {
    final bool asked = await _controller.refresh();
    if (!asked && mounted) {
      AppNotifications.show(
        context,
        dashboardStrings(context).dashRefreshFailed,
      );
    }
  }

  void _setEditing(bool on) {
    if (on) HapticFeedback.mediumImpact();
    setState(() => _editing = on);
  }

  Future<void> _confirmRemove(DashboardWidget w) async {
    final AppLocalizations l = dashboardStrings(context);
    final ThemeData theme = Theme.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        backgroundColor: theme.m3.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusDialog),
        ),
        title: Text(l.dashRemoveTitle(w.title)),
        content: Text(l.dashRemoveBody),
        actions: <Widget>[
          ExpressiveButton(
            tonal: true,
            dense: true,
            label: l.dashCancel,
            onTap: () => Navigator.of(dialog).pop(false),
          ),
          ExpressiveButton(
            dense: true,
            label: l.dashRemove,
            color: theme.colorScheme.error,
            onColor: theme.colorScheme.onError,
            onTap: () => Navigator.of(dialog).pop(true),
          ),
        ],
      ),
    );
    if (ok == true) await _controller.remove(w.id);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double top = MediaQuery.paddingOf(context).top + widget.topChrome;
    final double bottom = MediaQuery.paddingOf(context).bottom;
    final AppLocalizations l = dashboardStrings(context);
    final String? name = widget.assistantName?.trim();
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (BuildContext context, _) => _buildBody(context, top),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: top + 18,
          child: IgnorePointer(
            child: DecoratedBox(decoration: topVeilDecoration(scheme)),
          ),
        ),
        if (!_editing && widget.showAskPill)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: bottomVeilDecoration(scheme),
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 22, 16, bottom + 14),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: _AskPill(
                      label: name == null || name.isEmpty
                          ? l.dashAskAssistant
                          : l.dashAskNamed(name),
                      onTap: () =>
                          MainAgentLauncher.instance.openWithPrompt(''),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBody(BuildContext context, double top) {
    final DashboardDocument doc = _controller.document;
    final DateTime now = _now();
    final bool editing = _editing && !doc.isEmpty;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final bool wide = box.maxWidth >= kDashboardWideBreakpoint;
        final int columns = wide ? 4 : 2;
        final double width = box.maxWidth > 1120 ? 1120 : box.maxWidth;
        final double side = (box.maxWidth - width) / 2 + _kSide;
        final EdgeInsets pad = EdgeInsets.fromLTRB(
          side,
          top + 8,
          side,
          MediaQuery.paddingOf(context).bottom +
              (editing ? 32 : widget.bottomChrome ?? _kAskPillSpace + 16),
        );
        WeatherWidget? weather;
        for (final DashboardWidget w in doc.widgets) {
          if (w is WeatherWidget) {
            weather = w;
            break;
          }
        }
        final List<Widget> children = <Widget>[
          _Header(
            now: now,
            editing: editing,
            canEdit: !doc.isEmpty,
            attached: _controller.attached,
            pending: _controller.pendingCount,
            weather: weather,
            onEdit: () => _setEditing(!editing),
          ),
        ];
        if (!_controller.loaded && doc.isEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.only(top: 80),
              child: Center(
                child: Semantics(
                  label: dashboardStrings(context).dashLoading,
                  child: const ExpressiveLoader(size: 40),
                ),
              ),
            ),
          );
        } else if (doc.isEmpty) {
          children.add(const _EmptyState());
        } else {
          final List<List<DashboardWidget>> rows = packDashboardRows(
            doc.widgets,
            columns,
          );
          for (int i = 0; i < rows.length; i++) {
            children.add(
              StaggeredItem(
                key: ValueKey<String>('dash-row-${rows[i].first.id}'),
                index: i,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: _kGap),
                  child: _buildRow(
                    doc,
                    rows[i],
                    columns,
                    now,
                    editing,
                    width - 2 * _kSide,
                  ),
                ),
              ),
            );
          }
        }
        return RefreshIndicator(
          edgeOffset: top,
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: pad,
            children: children,
          ),
        );
      },
    );
  }

  Widget _buildRow(
    DashboardDocument doc,
    List<DashboardWidget> row,
    int columns,
    DateTime now,
    bool editing,
    double inner,
  ) {
    final double column = (inner - _kGap * (columns - 1)) / columns;
    int used = 0;
    final List<Widget> cells = <Widget>[];
    for (final DashboardWidget w in row) {
      final int span = dashboardSpan(w, columns);
      used += span;
      if (cells.isNotEmpty) cells.add(const SizedBox(width: _kGap));
      cells.add(
        Expanded(
          flex: span,
          child: editing
              ? _EditableCell(
                  key: ValueKey<String>('dash-tile-${w.id}'),
                  widget: w,
                  width: column * span + _kGap * (span - 1),
                  tile: _tile(w, now),
                  onMove: (String id) =>
                      _controller.move(id, doc.widgets.indexOf(w)),
                  onResize: () => _controller.update(w.id, <String, dynamic>{
                    'size': w.size == DashboardSize.half ? 'full' : 'half',
                  }),
                  onRemove: () => _confirmRemove(w),
                )
              : GestureDetector(
                  key: ValueKey<String>('dash-tile-${w.id}'),
                  behavior: HitTestBehavior.deferToChild,
                  onLongPress: () => _setEditing(true),
                  child: _tile(w, now),
                ),
        ),
      );
    }
    // A row that is not full keeps its columns: a lone half tile stays half.
    if (used < columns) {
      cells.add(const SizedBox(width: _kGap));
      cells.add(Spacer(flex: columns - used));
    }
    final bool sameHeight =
        row.length > 1 &&
        row.every(
          (DashboardWidget w) =>
              w.type != DashboardWidgetType.chart &&
              w.type != DashboardWidgetType.note,
        );
    final Widget line = Row(
      crossAxisAlignment: sameHeight
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.start,
      children: cells,
    );
    return sameHeight
        ? IntrinsicHeight(child: DashboardTileFill(child: line))
        : line;
  }

  Widget _tile(DashboardWidget w, DateTime now) => switch (w) {
    TrackerWidget t => TrackerTile(
      tracker: t,
      controller: _controller,
      now: now,
    ),
    MetricWidget m => MetricTile(metric: m, now: now),
    ChecklistWidget c => ChecklistTile(
      checklist: c,
      controller: _controller,
      now: now,
    ),
    NoteWidget n => NoteTile(note: n, now: now),
    ChartWidget c => ChartTile(chart: c, now: now),
    AgendaWidget a => AgendaTile(agenda: a, now: now),
    PromptsWidget p => PromptsTile(prompts: p, now: now),
    WeatherWidget wx => WeatherTile(weather: wx, now: now),
  };
}

String _greeting(AppLocalizations l, DateTime now) {
  final int h = now.hour;
  if (h >= 5 && h < 12) return l.dashGoodMorning;
  if (h >= 12 && h < 18) return l.dashGoodAfternoon;
  if (h >= 18 && h < 23) return l.dashGoodEvening;
  return l.dashGoodNight;
}

class _Header extends StatelessWidget {
  const _Header({
    required this.now,
    required this.editing,
    required this.canEdit,
    required this.attached,
    required this.pending,
    required this.weather,
    required this.onEdit,
  });

  final DateTime now;
  final bool editing;
  final bool canEdit;
  final bool attached;
  final int pending;
  final WeatherWidget? weather;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = dashboardStrings(context);
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final String locale =
        Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'en';
    final String date = DateFormat.MMMMd(locale).format(now);
    final String waiting = pending == 1
        ? l.dashPending1
        : (pending > 1 ? l.dashPendingN('$pending') : '');
    final List<Widget> pills = <Widget>[
      if (!editing && weather != null && weather!.temp != null)
        _StatusPill(
          icon: weatherGlyph(weather!.code),
          label: <String>[
            '${weather!.temp!.round()}°',
            if (weather!.place.isNotEmpty) weather!.place,
          ].join('  '),
        ),
      if (!attached)
        _StatusPill(
          key: const ValueKey<String>('dash-status'),
          icon: HugeIcons.cloudOff,
          label: waiting.isEmpty
              ? l.dashOffline
              : '${l.dashOffline} · $waiting',
          warn: true,
        )
      else if (waiting.isNotEmpty)
        _StatusPill(
          key: const ValueKey<String>('dash-status'),
          icon: HugeIcons.refresh,
          label: waiting,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (!editing) ...<Widget>[
                      Text(
                        _greeting(l, now),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: m3.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      editing ? l.dashEdit : l.dashTodayTitle(date),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        height: 1.15,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (editing) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        l.dashEditHint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: m3.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (canEdit) ...<Widget>[
                const SizedBox(width: 12),
                if (editing)
                  ExpressiveButton(
                    key: const ValueKey<String>('dash-edit-done'),
                    dense: true,
                    color: theme.colorScheme.onSurface,
                    onColor: theme.colorScheme.surface,
                    label: l.dashDone,
                    onTap: onEdit,
                  )
                else
                  FloatingHeaderButton(
                    key: const ValueKey<String>('dash-edit'),
                    hugeIcon: HugeIcons.pencilEdit02,
                    tooltip: l.dashEdit,
                    onPressed: onEdit,
                  ),
              ],
            ],
          ),
          if (pills.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(spacing: 8, runSpacing: 8, children: pills),
            ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    super.key,
    required this.icon,
    required this.label,
    this.warn = false,
  });

  final HugeIconData icon;
  final String label;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final Color fill = warn ? m3.warningContainer : dashboardCardFill(theme);
    final Color ink = warn
        ? m3.onWarningContainer
        : theme.colorScheme.onSurface;
    return DecoratedBox(
      decoration: ShapeDecoration(color: fill, shape: const StadiumBorder()),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 14, 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            HugeIcon(icon, size: 16, color: ink),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The floating "Ask … anything" pill at the bottom of Home.
class _AskPill extends StatelessWidget {
  const _AskPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final Color accent = theme.colorScheme.primary;
    return Semantics(
      button: true,
      label: label,
      child: MorphTap(
        key: const ValueKey<String>('dash-ask'),
        onTap: onTap,
        pressedScale: 0.97,
        color: m3.surfaceContainerHigh,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            DecoratedBox(
              decoration: ShapeDecoration(
                color: accent,
                shape: const CookieShape(lobes: 8, softness: 0.08),
              ),
              child: SizedBox(
                width: 38,
                height: 38,
                child: Center(
                  child: HugeIcon(
                    HugeIcons.sparkles,
                    size: 18,
                    color: readableOnFill(accent, theme.colorScheme.onPrimary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: m3.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = dashboardStrings(context);
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final List<(String, String, String, HugeIconData)> suggestions =
        <(String, String, String, HugeIconData)>[
          (
            l.dashSuggestPushups,
            l.dashSuggestPushupsDesc,
            l.dashSuggestPushupsPrompt,
            HugeIcons.dumbbell01,
          ),
          (
            l.dashSuggestWater,
            l.dashSuggestWaterDesc,
            l.dashSuggestWaterPrompt,
            HugeIcons.droplet,
          ),
          (
            l.dashSuggestWeather,
            l.dashSuggestWeatherDesc,
            l.dashSuggestWeatherPrompt,
            HugeIcons.sunCloud01,
          ),
        ];
    return StaggeredItem(
      index: 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
            decoration: BoxDecoration(
              color: dashboardCardFill(theme),
              borderRadius: BorderRadius.circular(kDashboardCardRadius + 6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DashboardBadge(
                  icon: HugeIcons.dashboardSquare01,
                  size: 60,
                  fill: m3.primaryContainer,
                  glyph: m3.onPrimaryContainer,
                  shape: const CookieShape(lobes: 9, softness: 0.1),
                ),
                const SizedBox(height: 16),
                Text(
                  l.dashEmptyTitle,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l.dashEmptyBody,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: m3.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 24, 6, 10),
            child: Text(
              l.dashGetStarted,
              style: theme.textTheme.titleSmall?.copyWith(
                color: m3.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final (
                String title,
                String desc,
                String prompt,
                HugeIconData icon,
              )
              in suggestions) ...<Widget>[
            _SuggestionCard(
              key: ValueKey<String>('dash-suggest-$title'),
              title: title,
              description: desc,
              icon: icon,
              onTap: () => MainAgentLauncher.instance.openWithPrompt(prompt),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// A dashed-outline card: "this is not there yet, tap to make it".
class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String description;
  final HugeIconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    const double radius = kDashboardCardRadius;
    return Semantics(
      button: true,
      child: MorphTap(
        onTap: onTap,
        pressedScale: 0.98,
        pressedColor: dashboardCardFill(theme),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: CustomPaint(
          painter: _DashedOutlinePainter(
            color: m3.outline.withValues(alpha: 0.6),
            radius: radius,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                DashboardBadge(icon: icon, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        title,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: m3.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                HugeIcon(
                  HugeIcons.plusSign,
                  size: 20,
                  color: m3.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedOutlinePainter extends CustomPainter {
  const _DashedOutlinePainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Path path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.75),
          Radius.circular(radius),
        ),
      );
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    for (final PathMetric metric in path.computeMetrics()) {
      for (double d = 0; d < metric.length; d += 10) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutlinePainter old) =>
      old.color != color || old.radius != radius;
}

/// A card in edit mode: the same tile, a minus badge on its corner, a size
/// chip, and hold-and-drag to move it onto another card's place.
class _EditableCell extends StatelessWidget {
  const _EditableCell({
    super.key,
    required this.widget,
    required this.width,
    required this.tile,
    required this.onMove,
    required this.onResize,
    required this.onRemove,
  });

  final DashboardWidget widget;

  /// The cell's width, for the card that follows the finger. Not measured
  /// with a LayoutBuilder: the row asks its cells for their intrinsic height.
  final double width;
  final Widget tile;

  /// Moves the dragged widget (its id) to this card's place.
  final ValueChanged<String> onMove;
  final VoidCallback onResize;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = dashboardStrings(context);
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final bool half = widget.size == DashboardSize.half;
    Widget decorated(bool target) => Stack(
      clipBehavior: Clip.none,
      // Passthrough: a stretched row hands its height on to the tile.
      fit: StackFit.passthrough,
      children: <Widget>[
        AnimatedScale(
          scale: target ? 0.95 : 1,
          duration: kExpressiveShort,
          curve: kExpressiveDecelerate,
          child: IgnorePointer(child: tile),
        ),
        Positioned(
          top: -6,
          left: -6,
          child: Semantics(
            button: true,
            label: l.dashRemove,
            child: MorphTap(
              key: ValueKey<String>('dash-remove-${widget.id}'),
              onTap: onRemove,
              color: m3.surfaceContainerHighest,
              shape: const CircleBorder(),
              child: SizedBox(
                width: 30,
                height: 30,
                child: Center(
                  child: HugeIcon(
                    HugeIcons.minusSign,
                    size: 16,
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 8,
          top: 9,
          child: Semantics(
            button: true,
            label: half ? l.dashSizeHalf : l.dashSizeFull,
            child: MorphTap(
              key: ValueKey<String>('dash-size-${widget.id}'),
              onTap: onResize,
              color: m3.surfaceContainerHighest,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.all(10),
              // Glyph only: a label would cover the title of a half tile.
              child: _SizeGlyphLabel(half: half),
            ),
          ),
        ),
      ],
    );
    return DragTarget<String>(
      onWillAcceptWithDetails: (DragTargetDetails<String> d) =>
          d.data != widget.id,
      onAcceptWithDetails: (DragTargetDetails<String> d) {
        HapticFeedback.selectionClick();
        onMove(d.data);
      },
      builder: (BuildContext context, List<String?> hovering, _) =>
          LongPressDraggable<String>(
            data: widget.id,
            hapticFeedbackOnStart: true,
            feedback: Material(
              type: MaterialType.transparency,
              child: SizedBox(
                width: width,
                child: Transform.scale(
                  scale: 1.03,
                  child: Opacity(opacity: 0.94, child: tile),
                ),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.25, child: decorated(false)),
            child: decorated(hovering.isNotEmpty),
          ),
    );
  }
}

/// Two small boxes, one or both filled: the width a widget takes, drawn
/// instead of a glyph that would need explaining.
class _SizeGlyphLabel extends StatelessWidget {
  const _SizeGlyphLabel({required this.half});

  final bool half;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color ink = theme.colorScheme.onSurface;
    Widget box(bool on) => Container(
      width: 7,
      height: 12,
      decoration: BoxDecoration(
        color: on ? ink : Colors.transparent,
        border: Border.all(color: ink, width: 1.4),
        borderRadius: BorderRadius.circular(2.5),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[box(true), const SizedBox(width: 2), box(!half)],
    );
  }
}
