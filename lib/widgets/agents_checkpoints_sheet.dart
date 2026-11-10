/// The "Checkpoints" sheet of an Agents thread, the rewind conflict choice
/// and "Fork from here" (docs/WIRE_CONTRACT.md, "Checkpoints, rewind and
/// fork", App work 1-4).
///
/// The sheet lists the thread's checkpoints, newest first, each with
/// "Rewind files to here". A rewind first goes out `safe`; when the user
/// changed files since the checkpoint, the host changes nothing and names
/// them, and the app asks: keep my edits, merge, or overwrite everything
/// (with a confirm). What the rewind did is shown after it, with the note
/// that sent mail and other outside effects stay. While the agent runs, the
/// host refuses a rewind (`busy`), and the sheet says so up front.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_checkpoints.dart';
import 'package:chuk_chat/services/agents/agents_derived_threads.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

/// The agent's name per thread, for "Wait until (agent) is done". The thread
/// view writes it; the chat screens' message actions read it.
final Map<String, String> agentsThreadAgentNames = <String, String>{};

/// Opens the sheet for [sessionKey].
Future<void> showAgentsCheckpointsSheet(
  BuildContext context, {
  required String sessionKey,
  String agentName = '',
  AgentsCheckpoints? service,
  AgentsRunLedger? ledger,
}) {
  return expressiveSheet<void>(
    context,
    title: _l10n(context).ckTitle,
    child: AgentsCheckpointsPanel(
      sessionKey: sessionKey,
      agentName: agentName,
      service: service,
      ledger: ledger,
    ),
  );
}

/// What a failed request says to the user.
String agentsCheckpointError(
  AppLocalizations l,
  String? error,
  String agentName,
) {
  final String name = agentName.trim().isEmpty ? l.ckThisAgent : agentName;
  if (error == null || error == AgentsCheckpoints.errNotConnected) {
    return l.ckNotConnected;
  }
  if (error == AgentsCheckpoints.errTimeout) return l.ckTimeout;
  if (error.startsWith('busy')) return l.ckBusy(name);
  return l.ckFailed(error);
}

/// The content of the sheet. Public so a test can pump it bare.
class AgentsCheckpointsPanel extends StatefulWidget {
  const AgentsCheckpointsPanel({
    super.key,
    required this.sessionKey,
    this.agentName = '',
    this.service,
    this.ledger,
  });

  final String sessionKey;
  final String agentName;
  final AgentsCheckpoints? service;
  final AgentsRunLedger? ledger;

  @override
  State<AgentsCheckpointsPanel> createState() => _AgentsCheckpointsPanelState();
}

class _AgentsCheckpointsPanelState extends State<AgentsCheckpointsPanel> {
  AgentsCheckpoints get _service =>
      widget.service ?? AgentsCheckpoints.instance;
  AgentsRunLedger get _ledger => widget.ledger ?? AgentsRunLedger.instance;

  AgentsCheckpointList? _list;
  bool _loading = true;

  /// The checkpoint a rewind runs for.
  String? _rewinding;
  AgentsRewindResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ledger.addListener(_onLedger);
    unawaited(_load());
  }

  @override
  void dispose() {
    _ledger.removeListener(_onLedger);
    super.dispose();
  }

  void _onLedger() {
    if (mounted) setState(() {});
  }

  bool get _running => _ledger.isRunning(widget.sessionKey);

  Future<void> _load() async {
    final AgentsCheckpointList list = await _service.list(widget.sessionKey);
    if (!mounted) return;
    setState(() {
      _list = list;
      _loading = false;
    });
  }

  Future<void> _rewind(AgentsCheckpoint checkpoint) async {
    if (_rewinding != null || _running) return;
    setState(() {
      _rewinding = checkpoint.id;
      _result = null;
      _error = null;
    });
    AgentsRewindResult result = await _service.rewind(
      widget.sessionKey,
      checkpoint.id,
    );
    if (mounted && result.hasConflicts) {
      final String? mode = await showRewindConflictDialog(
        context,
        result.conflicts,
      );
      if (mode != null) {
        result = await _service.rewind(
          widget.sessionKey,
          checkpoint.id,
          mode: mode,
        );
      } else {
        if (mounted) setState(() => _rewinding = null);
        return;
      }
    }
    if (!mounted) return;
    final AppLocalizations l = _l10n(context);
    setState(() {
      _rewinding = null;
      if (result.ok) {
        _result = result;
      } else {
        _error = agentsCheckpointError(l, result.error, widget.agentName);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l = _l10n(context);
    final String name = widget.agentName.trim().isEmpty
        ? l.ckThisAgent
        : widget.agentName;
    final AgentsCheckpointList? list = _list;
    final List<Widget> children = <Widget>[
      Text(
        l.ckIntro,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 14),
      if (_running) ...<Widget>[
        _Notice(
          key: const ValueKey<String>('agents-checkpoints-running'),
          icon: HugeIcons.loading03,
          text: l.ckRunningHint(name),
        ),
        const SizedBox(height: 10),
      ],
      if (_error case final String error) ...<Widget>[
        _Notice(
          key: const ValueKey<String>('agents-checkpoints-error'),
          icon: HugeIcons.alertCircle,
          text: error,
          error: true,
        ),
        const SizedBox(height: 10),
      ],
      if (_result case final AgentsRewindResult result) ...<Widget>[
        AgentsRewindSummary(result: result),
        const SizedBox(height: 10),
      ],
      if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (list == null || !list.ok)
        _Notice(
          key: const ValueKey<String>('agents-checkpoints-load-error'),
          icon: HugeIcons.alertCircle,
          text: agentsCheckpointError(l, list?.error, widget.agentName),
          error: true,
        )
      else if (list.items.isEmpty)
        Text(
          l.ckEmpty,
          key: const ValueKey<String>('agents-checkpoints-empty'),
          style: theme.textTheme.bodyMedium,
        )
      else
        for (final AgentsCheckpoint c in list.items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _CheckpointRow(
              checkpoint: c,
              busy: _rewinding == c.id,
              enabled: _rewinding == null && !_running,
              onRewind: () => unawaited(_rewind(c)),
            ),
          ),
    ];
    return Flexible(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          child: Column(
            key: const ValueKey<String>('agents-checkpoints-panel'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// One checkpoint: when, what the user asked, and the rewind button.
class _CheckpointRow extends StatelessWidget {
  const _CheckpointRow({
    required this.checkpoint,
    required this.busy,
    required this.enabled,
    required this.onRewind,
  });

  final AgentsCheckpoint checkpoint;
  final bool busy;
  final bool enabled;
  final VoidCallback onRewind;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l = _l10n(context);
    final DateTime? at = checkpoint.createdAt;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String when = at == null
        ? ''
        : DateFormat.yMMMd(locale).add_Hm().format(at.toLocal());
    return Container(
      key: ValueKey<String>('agents-checkpoint-${checkpoint.id}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(kRadiusXl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (when.isNotEmpty)
            Text(
              when,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          const SizedBox(height: 2),
          Text(
            checkpoint.prompt.isEmpty ? l.ckUntitled : checkpoint.prompt,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: busy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Opacity(
                    opacity: enabled ? 1 : 0.45,
                    child: IgnorePointer(
                      ignoring: !enabled,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: ExpressiveButton(
                          key: ValueKey<String>(
                            'agents-checkpoint-rewind-${checkpoint.id}',
                          ),
                          label: l.ckRewind,
                          tonal: true,
                          dense: true,
                          onTap: onRewind,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A one-line notice in the sheet (running, an error).
class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.text,
    this.error = false,
  });

  final HugeIconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color fg = error ? scheme.onErrorContainer : scheme.onSurface;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kRadiusLg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            height: 20,
            child: Center(child: HugeIcon(icon, size: 18, color: fg)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: fg,
                height: 20 / 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What a rewind did: restored, merged, kept and refused paths, and that
/// effects outside the files stay.
class AgentsRewindSummary extends StatelessWidget {
  const AgentsRewindSummary({super.key, required this.result});

  final AgentsRewindResult result;

  static const int _shown = 6;

  String _files(AppLocalizations l, List<String> paths) {
    if (paths.length <= _shown) return paths.join(', ');
    return '${paths.take(_shown).join(', ')} ${l.ckMore('${paths.length - _shown}')}';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l = _l10n(context);
    final bool changed = result.restored.isNotEmpty || result.merged.isNotEmpty;
    Widget line(String key, String text) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        key: ValueKey<String>(key),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurface),
      ),
    );
    return Container(
      key: const ValueKey<String>('agents-rewind-summary'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(kRadiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            changed ? l.ckDone : l.ckNothing,
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (result.restored.isNotEmpty)
            line(
              'agents-rewind-restored',
              l.ckRestored(_files(l, result.restored)),
            ),
          if (result.merged.isNotEmpty)
            line('agents-rewind-merged', l.ckMerged(_files(l, result.merged))),
          if (result.kept.isNotEmpty)
            line('agents-rewind-kept', l.ckKept(_files(l, result.kept))),
          if (result.refused.isNotEmpty)
            line(
              'agents-rewind-refused',
              l.ckRefused(_files(l, result.refused)),
            ),
          const SizedBox(height: 6),
          Text(
            l.ckOutside,
            key: const ValueKey<String>('agents-rewind-outside'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks what a rewind does with the files the user changed since the
/// checkpoint. Returns `keep_user_edits`, `merge` or `force` (after a
/// confirm), or null when the user cancels.
Future<String?> showRewindConflictDialog(
  BuildContext context,
  List<String> conflicts,
) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) =>
        _ConflictDialog(conflicts: conflicts),
  );
}

class _ConflictDialog extends StatelessWidget {
  const _ConflictDialog({required this.conflicts});

  final List<String> conflicts;

  static const int _shown = 8;

  Future<void> _overwrite(BuildContext context) async {
    final AppLocalizations l = _l10n(context);
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        key: const ValueKey<String>('agents-rewind-force-confirm'),
        title: Text(l.ckOverwriteTitle),
        content: Text(l.ckOverwriteBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(c).pop(false),
            child: Text(l.ckCancel),
          ),
          TextButton(
            key: const ValueKey<String>('agents-rewind-force-yes'),
            onPressed: () => Navigator.of(c).pop(true),
            child: Text(l.ckOverwrite),
          ),
        ],
      ),
    );
    if (sure == true && context.mounted) {
      Navigator.of(context).pop(AgentsRewindMode.force);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l = _l10n(context);
    final List<String> shown = conflicts.take(_shown).toList();
    return Dialog(
      key: const ValueKey<String>('agents-rewind-conflicts'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusDialog),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(l.ckConflictTitle, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(l.ckConflictBody, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(kRadiusLg),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final String path in shown)
                      Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          fontFamilyFallback: const <String>['Courier'],
                        ),
                      ),
                    if (conflicts.length > _shown)
                      Text(
                        l.ckMore('${conflicts.length - _shown}'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: <Widget>[
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ExpressiveButton(
                      key: const ValueKey<String>('agents-rewind-keep'),
                      label: l.ckKeepEdits,
                      dense: true,
                      onTap: () =>
                          Navigator.of(context)
                              .pop(AgentsRewindMode.keepUserEdits),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ExpressiveButton(
                      key: const ValueKey<String>('agents-rewind-merge'),
                      label: l.ckMerge,
                      tonal: true,
                      dense: true,
                      onTap: () =>
                          Navigator.of(context).pop(AgentsRewindMode.merge),
                    ),
                  ),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ExpressiveButton(
                      key: const ValueKey<String>('agents-rewind-force'),
                      label: l.ckOverwrite,
                      tonal: true,
                      dense: true,
                      onTap: () => unawaited(_overwrite(context)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const ValueKey<String>('agents-rewind-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l.ckCancel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Fork from here" for one stored message of an Agents thread: null for
/// every other chat and for a message the host has no `mid` for.
MessageBubbleAction? agentsForkAction(
  BuildContext context,
  String? chatId,
  Map<String, String> message, {
  AgentsCheckpoints? service,
}) {
  if (chatId == null || !ChatOrigin.isAgentsThread(chatId)) return null;
  final int? mid = int.tryParse(message[kAgentsHostMidKey] ?? '');
  if (mid == null) return null;
  final String label = _l10n(context).ckFork;
  return MessageBubbleAction(
    icon: Icons.alt_route,
    tooltip: label,
    label: label,
    onPressed: () => unawaited(
      forkAgentsThreadFrom(
        context,
        sessionKey: chatId,
        mid: mid,
        messageText: message['text'] ?? '',
        service: service,
      ),
    ),
  );
}

/// Forks [sessionKey] at [mid] and opens the new thread. When the host made
/// the thread but did not restore the files (the user changed some since),
/// the user picks keep / merge / overwrite and the app rewinds to the
/// checkpoint the host named.
Future<AgentsForkResult> forkAgentsThreadFrom(
  BuildContext context, {
  required String sessionKey,
  required int mid,
  String messageText = '',
  AgentsCheckpoints? service,
  AgentsDerivedThreads? threads,
}) async {
  final AgentsCheckpoints checkpoints = service ?? AgentsCheckpoints.instance;
  final AppLocalizations l = _l10n(context);
  final String agentName = agentsThreadAgentNames[sessionKey] ?? '';
  final AgentsForkResult result = await checkpoints.fork(sessionKey, mid);
  if (!context.mounted) return result;
  final String? newKey = result.newSessionKey;
  if (!result.ok || newKey == null) {
    pillToast(context, agentsCheckpointError(l, result.error, agentName));
    return result;
  }
  String text = messageText.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.length > 40) text = '${text.substring(0, 40)}…';
  (threads ?? AgentsDerivedThreads.instance).addFork(
    key: newKey,
    sourceKey: sessionKey,
    title: l.ckForkTitle(text.isEmpty ? '#$mid' : text),
  );
  final String? checkpointId = result.checkpointId;
  final AgentsRewindResult? workspace = result.workspace;
  if (result.needsWorkspaceChoice && checkpointId != null) {
    final String? mode = await showRewindConflictDialog(
      context,
      workspace?.conflicts ?? const <String>[],
    );
    if (mode != null) {
      final AgentsRewindResult rewound = await checkpoints.rewind(
        newKey,
        checkpointId,
        mode: mode,
      );
      if (context.mounted) {
        pillToast(
          context,
          rewound.ok
              ? l.ckDone
              : agentsCheckpointError(l, rewound.error, agentName),
        );
      }
    }
  } else if (workspace != null && !workspace.ok && context.mounted) {
    pillToast(context, agentsCheckpointError(l, workspace.error, agentName));
  } else if (context.mounted) {
    pillToast(context, l.ckForked);
  }
  AgentsCheckpoints.requestOpen(newKey);
  return result;
}
