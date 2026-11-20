/// The first page of the desktop details pane: everything about the agent
/// that is needed often, in one list: its screen, its routines, its model,
/// its files and the thread's actions ([actions]).
///
///  * [AgentScreenPreview]: a 16:10 box for the agent's screen, with the
///    caption "`<name>`'s screen" under it. The app has no picture of the
///    screen until the viewer opens, so the box shows the screen state, not a
///    thumbnail: lit with "Open screen" while the host offers a screen (a tap
///    opens the existing full-screen viewer), quiet while it does not (a tap
///    says so, in the words of the thread header's screen target).
///  * [AgentRoutinesList]: the agent's scheduled and watching automations
///    from [AutomationsSource], one row each, with a plain schedule line. A
///    tap opens the existing automation editor (or the Automations page for a
///    kind the editor does not take).
///
/// The settings (name, role, description, model, budget and the technical
/// blocks) are the second page, [AgentControlPanel] in its profile layout.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/automations_page.dart';
import 'package:chuk_chat/services/agents/agent_model.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/automation_editor_sheet.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/widgets/settings_surface.dart';

/// The root page: the screen box, then the routines.
class AgentDetailsOverview extends StatelessWidget {
  const AgentDetailsOverview({
    super.key,
    required this.name,
    required this.sessionKey,
    this.onOpenScreen,
    this.onScreenParked,
    this.automations,
    this.onOpenModel,
    this.onOpenFiles,
    this.actions = const <AgentDetailsAction>[],
    this.modelReader,
    this.headerInset = false,
  });

  /// True under a floating header ([FloatingPageScaffold]): the list starts
  /// below the header and scrolls up behind it.
  final bool headerInset;

  /// Opens the agent's model setting. Null hides the Model row.
  final VoidCallback? onOpenModel;

  /// Opens the thread's files. Null hides the Files row.
  final VoidCallback? onOpenFiles;

  /// The thread's other actions (checkpoints, copy, rename), one row each.
  final List<AgentDetailsAction> actions;

  /// Reads the agent's model. Tests pass their own.
  final Future<AgentModelSummary> Function(String sessionKey)? modelReader;

  final String name;

  /// The agent's thread key: its automations are filed under it.
  final String sessionKey;

  /// Opens the screen viewer. Null while there is no screen on offer.
  final VoidCallback? onOpenScreen;

  /// A tap on the box while there is no screen. Defaults to a short note.
  final VoidCallback? onScreenParked;

  final AutomationsSource? automations;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? openModel = onOpenModel;
    return ListView(
      key: const ValueKey<String>('details-overview'),
      padding: const EdgeInsets.fromLTRB(
        16,
        16,
        16,
        24,
      ).add(headerInset ? floatingHeaderInset(context) : EdgeInsets.zero),
      children: <Widget>[
        AgentScreenPreview(
          name: name,
          onOpen: onOpenScreen,
          onParked: onScreenParked,
        ),
        // The routines' section label carries its own space above.
        const SizedBox(height: 8),
        AgentRoutinesList(
          sessionKey: sessionKey,
          agentName: name,
          source: automations,
        ),
        if (openModel != null || onOpenFiles != null) ...<Widget>[
          const SizedBox(height: 24),
          ExpressiveGroup(
            children: <Widget>[
              if (openModel != null)
                _AgentModelRow(
                  key: ValueKey<String>('details-model-$sessionKey'),
                  sessionKey: sessionKey,
                  onTap: openModel,
                  reader: modelReader ?? AgentModelSummary.read,
                ),
              if (onOpenFiles != null)
                ExpressiveRow(
                  key: const ValueKey<String>('details-files'),
                  icon: Icons.folder_open_rounded,
                  title: 'Files',
                  subtitle: 'Documents and files of this thread',
                  onTap: onOpenFiles,
                ),
            ],
          ),
        ],
        if (actions.isNotEmpty) ...<Widget>[
          const SizedBox(height: 24),
          ExpressiveGroup(
            children: <Widget>[
              for (final AgentDetailsAction action in actions)
                ExpressiveRow(
                  key: ValueKey<String>('details-action-${action.label}'),
                  icon: action.icon,
                  title: action.label,
                  onTap: action.onTap,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// One row of the details pane's action list.
@immutable
class AgentDetailsAction {
  const AgentDetailsAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// The model an agent runs on, in words for the details pane.
@immutable
class AgentModelSummary {
  const AgentModelSummary({required this.name, required this.provider});

  /// "DeepSeek V4.1 Flash".
  final String name;

  /// "Auto", or the pinned provider's slug.
  final String provider;

  /// The agent's model as the app sends it to the host
  /// ([AgentModel.resolveOrFallback]), named from the cached catalogue.
  static Future<AgentModelSummary> read(String sessionKey) async {
    final AgentModelState state = await AgentModel.resolveOrFallback(sessionKey)
        .timeout(AgentModel.loadTimeout, onTimeout: AgentModel.fallbackState);
    final String id = state.modelId;
    String name = id.contains('/') ? id.split('/').last : id;
    try {
      for (final AgentCatalogueModel m in await AgentModel.catalogue()) {
        if (m.id == id) {
          name = m.shortName;
          break;
        }
      }
    } catch (_) {
      // The catalogue is only for the name; the id still says it.
    }
    final String slug = state.providerSlug;
    return AgentModelSummary(
      name: name,
      provider: slug.isEmpty ? 'Auto' : slug,
    );
  }
}

class _AgentModelRow extends StatefulWidget {
  const _AgentModelRow({
    super.key,
    required this.sessionKey,
    required this.onTap,
    required this.reader,
  });

  final String sessionKey;
  final VoidCallback onTap;
  final Future<AgentModelSummary> Function(String sessionKey) reader;

  @override
  State<_AgentModelRow> createState() => _AgentModelRowState();
}

class _AgentModelRowState extends State<_AgentModelRow> {
  late Future<AgentModelSummary> _summary = widget.reader(widget.sessionKey);

  @override
  void didUpdateWidget(_AgentModelRow old) {
    super.didUpdateWidget(old);
    if (old.sessionKey != widget.sessionKey) {
      _summary = widget.reader(widget.sessionKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AgentModelSummary>(
      future: _summary,
      builder: (BuildContext context, AsyncSnapshot<AgentModelSummary> snap) {
        final AgentModelSummary? summary = snap.data;
        return ExpressiveRow(
          key: const ValueKey<String>('details-model'),
          icon: Icons.auto_awesome_outlined,
          title: 'Model',
          subtitle: summary == null
              ? '…'
              : '${summary.name} · ${summary.provider}',
          onTap: widget.onTap,
        );
      },
    );
  }
}

/// The agent's screen as a 16:10 box with a caption.
class AgentScreenPreview extends StatelessWidget {
  const AgentScreenPreview({
    super.key,
    required this.name,
    this.onOpen,
    this.onParked,
  });

  final String name;
  final VoidCallback? onOpen;

  /// A tap while there is no screen. Null says so in a short note, as the
  /// thread header's parked screen target does.
  final VoidCallback? onParked;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool live = onOpen != null;
    final Color surface = theme.m3.surfaceContainer;
    final Color glyph = live
        ? theme.accentForegroundOn(surface)
        : scheme.onSurfaceVariant.withValues(alpha: 0.7);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          button: true,
          label: live ? "Open $name's screen" : "$name's screen, not open",
          child: Material(
            key: const ValueKey<String>('details-screen'),
            color: surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: InkWell(
              onTap:
                  onOpen ??
                  onParked ??
                  () => AppNotifications.show(
                    context,
                    'The agent has no screen open right now',
                  ),
              child: AspectRatio(
                aspectRatio: 16 / 10,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AppIcon(
                        Icons.desktop_windows_rounded,
                        size: live ? 28 : 22,
                        color: glyph,
                      ),
                      if (live) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          'Open screen',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: glyph,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          "$name's screen",
          key: const ValueKey<String>('details-screen-caption'),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The agent's routines: its automations that are still running or
/// paused, one row each.
class AgentRoutinesList extends StatefulWidget {
  const AgentRoutinesList({
    super.key,
    required this.sessionKey,
    required this.agentName,
    this.source,
  });

  final String sessionKey;
  final String agentName;

  /// Defaults to [AutomationsSource.instance].
  final AutomationsSource? source;

  @override
  State<AgentRoutinesList> createState() => _AgentRoutinesListState();
}

class _AgentRoutinesListState extends State<AgentRoutinesList> {
  AutomationsSource get _source => widget.source ?? AutomationsSource.instance;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(AgentRoutinesList old) {
    super.didUpdateWidget(old);
    if (old.sessionKey != widget.sessionKey) _ask();
  }

  /// Asks the host once for this agent's list, unless it answered before.
  void _ask() {
    _source.attach();
    if (!_source.listed(widget.sessionKey)) {
      unawaited(_source.refresh(sessionKey: widget.sessionKey));
    }
  }

  Future<void> _open(AgentsAutomation automation) async {
    // The editor takes schedules and event triggers; a script watcher is
    // managed on the Automations page.
    if (!automation.isWatcher) {
      // The host's answer updates the source, and with it this row.
      await showAutomationEditor(
        context,
        existing: automation,
        source: _source,
      );
      return;
    }
    // A settings page: the settings modal on a desktop window, a page on a
    // phone (settings_surface.dart).
    await openSettingsSurface(
      context,
      (BuildContext context) => AutomationsPage(
        source: _source,
        sessionKey: widget.sessionKey,
        chatName: widget.agentName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations? l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _source,
      builder: (BuildContext context, Widget? _) {
        final List<AgentsAutomation> routines = _source.distinct
            .where(
              (AgentsAutomation a) =>
                  a.sessionKey == widget.sessionKey && !a.isOver,
            )
            .toList();
        return Column(
          key: const ValueKey<String>('details-routines'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // The same section label as every settings page.
            const ExpressiveSectionHeader('Routines'),
            if (routines.isEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  _source.listed(widget.sessionKey)
                      ? 'No routines yet.'
                      : 'No routines known yet.',
                  key: const ValueKey<String>('details-routines-empty'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              )
            else
              ExpressiveGroup(
                children: <Widget>[
                  for (final AgentsAutomation a in routines)
                    ExpressiveRow(
                      key: ValueKey<String>('details-routine-${a.id}'),
                      icon: Icons.schedule,
                      title: a.name.isEmpty ? a.trigger : a.name,
                      subtitle: a.isPaused
                          ? '${routineScheduleText(a)} · ${a.stateLabel(l10n)}'
                          : routineScheduleText(a),
                      onTap: () => unawaited(_open(a)),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// A plain reading of when a routine runs: "Every day at 08:13",
/// "Weekdays at 09:00", "Every 30 minutes", "Once at 2026-10-06 09:00".
/// A schedule this cannot put in words keeps the host's own label.
String routineScheduleText(AgentsAutomation automation) {
  final Object? cron = automation.spec['cron'];
  if (cron is String) return _cronText(cron) ?? 'cron $cron';
  if (automation.isSchedule) {
    final int? every = automation.everySeconds;
    if (every != null) return 'Every ${_spanText(every)}';
    final Object? at = automation.spec['at'];
    if (at is String) {
      final DateTime? when = DateTime.tryParse(at)?.toLocal();
      return when == null ? 'Once at $at' : 'Once at ${_dateTime(when)}';
    }
  }
  final String label = automation.specLabel;
  if (label.isEmpty) return label;
  return label[0].toUpperCase() + label.substring(1);
}

const List<String> _weekdays = <String>[
  'Sunday',
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

/// `13 8 * * *` → "Every day at 08:13". Only the plain shapes: a fixed
/// minute and hour, every day of the month, every month, and every day, the
/// weekdays, the weekend or one day of the week.
String? _cronText(String cron) {
  final List<String> f = cron.trim().split(RegExp(r'\s+'));
  if (f.length != 5) return null;
  final int? minute = int.tryParse(f[0]);
  final int? hour = int.tryParse(f[1]);
  if (minute == null || hour == null || f[2] != '*' || f[3] != '*') {
    return null;
  }
  if (minute < 0 || minute > 59 || hour < 0 || hour > 23) return null;
  final String time = '${_two(hour)}:${_two(minute)}';
  final String dow = f[4];
  if (dow == '*') return 'Every day at $time';
  if (dow == '1-5') return 'Weekdays at $time';
  if (dow == '0,6' || dow == '6,0' || dow == '6-7') return 'Weekends at $time';
  final int? day = int.tryParse(dow);
  if (day != null && day >= 0 && day <= 7) {
    return 'Every ${_weekdays[day % 7]} at $time';
  }
  return null;
}

/// 1800 → "30 minutes", 3600 → "hour", 86400 → "day", 7200 → "2 hours".
String _spanText(int seconds) {
  String unit(int count, String name) => count == 1 ? name : '$count ${name}s';
  if (seconds % 86400 == 0) return unit(seconds ~/ 86400, 'day');
  if (seconds % 3600 == 0) return unit(seconds ~/ 3600, 'hour');
  if (seconds % 60 == 0) return unit(seconds ~/ 60, 'minute');
  return unit(seconds, 'second');
}

String _two(int v) => v.toString().padLeft(2, '0');

String _dateTime(DateTime when) =>
    '${when.year}-${_two(when.month)}-${_two(when.day)} '
    '${_two(when.hour)}:${_two(when.minute)}';
