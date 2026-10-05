// lib/widgets/agents_run_changes_line.dart
//
// "What did it do" under a coworker's answer (docs/WIRE_CONTRACT.md, "What
// did it do: run changes and undo", bead chuk_chat-4qry).
//
// The line: "3 files changed · Undo", "3 files changed · 1 undone · Undo",
// or "Changes undone" with no Undo. It sits next to the cost line, in the
// same quiet meta style. A tap opens the sheet: one row per file with its
// change, path and line counts, a check box on the files that can be undone,
// the conflict reason under a file that changed later, the run's commits as
// a collapsed timeline, and the Undo button. The figure comes from the
// answer's hidden run meta call ([splitRunMeta]); after an undo the service
// holds the newer block.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_run_changes.dart';
import 'package:chuk_chat/services/agents/agents_run_changes_service.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/ui/expressive/motion.dart' show ExpressiveButton;
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

/// The line under an answer whose run changed workspace files.
class AgentsRunChangesLine extends StatelessWidget {
  const AgentsRunChangesLine({
    super.key,
    required this.runId,
    required this.changes,
    this.sessionKey,
    this.service,
    this.ledger,
  });

  /// The host's id of the run that wrote this answer.
  final String runId;

  /// The block the answer carries. The service's newer one wins.
  final AgentsRunChangesSummary changes;

  /// The thread, for "is the agent working right now".
  final String? sessionKey;

  /// Defaults to [AgentsRunChangesService.instance].
  final AgentsRunChangesService? service;

  /// Defaults to [AgentsRunLedger.instance].
  final AgentsRunLedger? ledger;

  /// "3 files changed · 1 undone" (without the Undo), or "Changes undone".
  static String label(AppLocalizations? l, AgentsRunChangesSummary changes) {
    if (changes.allUndone) return l?.runChangesAllUndone ?? 'Changes undone';
    final String files = changes.files == 1
        ? (l?.runChangesFilesOne ?? '1 file changed')
        : (l?.runChangesFilesMany(changes.files) ??
              '${changes.files} files changed');
    if (!changes.partlyUndone) return files;
    final String undone =
        l?.runChangesUndoneCount(changes.undone) ?? '${changes.undone} undone';
    return '$files · $undone';
  }

  @override
  Widget build(BuildContext context) {
    final AgentsRunChangesService source =
        service ?? AgentsRunChangesService.instance;
    return ListenableBuilder(
      listenable: source,
      builder: (BuildContext context, Widget? _) {
        final AgentsRunChangesSummary shown =
            source.summaryOf(runId) ?? changes;
        final ThemeData theme = Theme.of(context);
        final AppLocalizations? l = AppLocalizations.of(context);
        final TextStyle? base = theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        return Semantics(
          button: true,
          hint: l?.runChangesDetails ?? 'Show what this run changed',
          child: InkWell(
            key: const ValueKey<String>('agents-run-changes-line'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => showRunChangesSheet(
              context,
              runId: runId,
              sessionKey: sessionKey,
              service: source,
              ledger: ledger,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text.rich(
                TextSpan(
                  text: label(l, shown),
                  children: <InlineSpan>[
                    if (!shown.allUndone) ...<InlineSpan>[
                      const TextSpan(text: ' · '),
                      TextSpan(
                        text: l?.runChangesUndo ?? 'Undo',
                        style: TextStyle(
                          color: theme.accentForegroundOn(),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
                style: base,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Opens the changes sheet for [runId]. A successful undo closes it, shows a
/// snackbar with the count and, the first time, the host's note on what an
/// undo does not bring back.
Future<void> showRunChangesSheet(
  BuildContext context, {
  required String runId,
  String? sessionKey,
  AgentsRunChangesService? service,
  AgentsRunLedger? ledger,
}) async {
  final AgentsRunChangesService source =
      service ?? AgentsRunChangesService.instance;
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final AppLocalizations? l = AppLocalizations.of(context);
  final AgentsRunUndoResult? done =
      await showModalBottomSheet<AgentsRunUndoResult>(
        context: context,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        backgroundColor: scheme.surfaceContainerLow,
        showDragHandle: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
        ),
        isScrollControlled: true,
        builder: (BuildContext sheetContext) => RunChangesSheet(
          runId: runId,
          sessionKey: sessionKey,
          service: source,
          ledger: ledger ?? AgentsRunLedger.instance,
        ),
      );
  if (done == null || !done.ok) return;
  final int count = done.reverted.length;
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          count == 1
              ? (l?.runChangesUndidOne ?? '1 file undone')
              : (l?.runChangesUndidMany(count) ?? '$count files undone'),
        ),
      ),
    );
  final String? note = done.note;
  if (note == null || !context.mounted) return;
  if (!await source.claimUndoNote() || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      key: const ValueKey<String>('agents-run-undo-note'),
      title: Text(l?.runChangesNoteTitle ?? 'Files restored'),
      content: Text(note),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l?.runChangesNoteOk ?? 'OK'),
        ),
      ],
    ),
  );
}

/// The sheet's body. Pops with the [AgentsRunUndoResult] of a successful
/// undo.
class RunChangesSheet extends StatefulWidget {
  const RunChangesSheet({
    super.key,
    required this.runId,
    required this.service,
    required this.ledger,
    this.sessionKey,
  });

  final String runId;
  final String? sessionKey;
  final AgentsRunChangesService service;
  final AgentsRunLedger ledger;

  @override
  State<RunChangesSheet> createState() => _RunChangesSheetState();
}

class _RunChangesSheetState extends State<RunChangesSheet> {
  AgentsRunChangesReport? _report;
  final Set<String> _checked = <String>{};
  bool _busy = false;
  bool _hostActive = false;
  bool _ledgerRunning = false;
  bool _timelineOpen = false;

  /// An undo failure the user should read, already in their language.
  String? _undoError;

  String? get _sessionKey => _report?.sessionKey ?? widget.sessionKey;

  bool get _running => _ledgerRunning || _hostActive;

  @override
  void initState() {
    super.initState();
    _ledgerRunning = _isLedgerRunning();
    widget.ledger.addListener(_onLedger);
    _load();
  }

  @override
  void dispose() {
    widget.ledger.removeListener(_onLedger);
    super.dispose();
  }

  bool _isLedgerRunning() {
    final String? key = _sessionKey;
    return key != null && widget.ledger.isRunning(key);
  }

  void _onLedger() {
    final bool now = _isLedgerRunning();
    if (now == _ledgerRunning) return;
    final bool ended = _ledgerRunning && !now;
    setState(() => _ledgerRunning = now);
    // The agent is done: the files may have moved, and the host no longer
    // says `run_active`. Ask again.
    if (ended) _load();
  }

  Future<void> _load() async {
    final AgentsRunChangesReport report = await widget.service.fetch(
      widget.runId,
    );
    if (!mounted) return;
    setState(() {
      _report = report;
      _hostActive = report.runActive;
      _ledgerRunning = _isLedgerRunning();
      _undoError = null;
      _checked
        ..clear()
        ..addAll(<String>[
          for (final AgentsRunFile f in report.files)
            if (f.undoable && !f.undone) f.path,
        ]);
    });
  }

  /// A file the user can tick: one that can be undone, or one that conflicts
  /// (unticked; the host then asks for "Undo anyway").
  static bool _checkable(AgentsRunFile f) =>
      !f.undone && (f.undoable || f.conflict != null);

  Future<void> _undo({bool force = false}) async {
    final AgentsRunChangesReport? report = _report;
    if (report == null || _checked.isEmpty || _busy || _running) return;
    final List<String> paths = <String>[
      for (final AgentsRunFile f in report.files)
        if (_checked.contains(f.path)) f.path,
    ];
    setState(() {
      _busy = true;
      _undoError = null;
    });
    final AgentsRunUndoResult result = await widget.service.undo(
      widget.runId,
      paths: paths,
      force: force,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      Navigator.of(context).pop(result);
      return;
    }
    if (result.isConflicts) {
      if (await _confirmForce(result.conflicts) && mounted) {
        await _undo(force: true);
      }
      return;
    }
    if (result.isRunActive) {
      setState(() => _hostActive = true);
      return;
    }
    final AppLocalizations? l = AppLocalizations.of(context);
    setState(() {
      _undoError = result.error ?? _codeText(l, result.code);
    });
  }

  Future<bool> _confirmForce(List<AgentsRunConflict> conflicts) async {
    final AppLocalizations? l = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const ValueKey<String>('agents-run-undo-conflicts'),
        title: Text(
          l?.runChangesConflictTitle ?? 'These files changed after the run',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                l?.runChangesConflictBody ??
                    'Undo overwrites these later changes.',
              ),
              const SizedBox(height: 12),
              for (final AgentsRunConflict c in conflicts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        c.path,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _conflictText(l, c.reason),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l?.runChangesCancel ?? 'Cancel'),
          ),
          TextButton(
            key: const ValueKey<String>('agents-run-undo-anyway'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: Text(l?.runChangesUndoAnyway ?? 'Undo anyway'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final AgentsRunChangesReport? report = _report;
    final AgentsRunChangesSummary? summary =
        report?.summary ?? widget.service.summaryOf(widget.runId);

    final Widget header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              l?.runChangesSheetTitle ?? 'What this run changed',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (summary != null) ...<Widget>[
            const SizedBox(width: 12),
            Text(
              _lineCounts(summary.additions, summary.deletions),
              key: const ValueKey<String>('agents-run-changes-total'),
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            header,
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _body(context, report),
                ),
              ),
            ),
            ..._footer(context, report),
          ],
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, AgentsRunChangesReport? report) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final TextStyle? quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    if (report == null) {
      return <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 16),
          child: Row(
            children: <Widget>[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l?.runChangesLoading ?? 'Loading the changes…',
                  style: quiet,
                ),
              ),
            ],
          ),
        ),
      ];
    }
    final String? problem = report.failure != null
        ? _codeText(l, report.failure)
        : (report.files.isEmpty ? _reasonText(l, report.reason) : null);
    final Color tile = scheme.surfaceContainerHigh;
    return <Widget>[
      if (problem != null)
        Padding(
          key: const ValueKey<String>('agents-run-changes-problem'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          child: Text(problem, style: theme.textTheme.bodyMedium),
        ),
      if (report.files.isNotEmpty)
        MenuTileGroup(
          color: tile,
          groups: <List<Widget>>[
            <Widget>[
              for (final AgentsRunFile f in report.files)
                _FileRow(
                  file: f,
                  checkable: _checkable(f),
                  checked: _checked.contains(f.path),
                  onChanged: _busy
                      ? null
                      : (bool on) => setState(() {
                          if (on) {
                            _checked.add(f.path);
                          } else {
                            _checked.remove(f.path);
                          }
                        }),
                ),
            ],
          ],
        ),
      if (report.hiddenFiles > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
          child: Text(
            l?.runChangesMoreFiles(report.hiddenFiles) ??
                '${report.hiddenFiles} more files are not listed',
            style: quiet,
          ),
        ),
      if (report.commits.isNotEmpty) ...<Widget>[
        const SizedBox(height: kMenuGroupGap),
        MenuTileGroup(
          color: tile,
          groups: <List<Widget>>[
            <Widget>[
              _timelineHead(context, report),
              if (_timelineOpen)
                for (final AgentsRunCommit c in report.commits)
                  _CommitRow(commit: c),
            ],
          ],
        ),
      ],
      if (report.files.isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text(
            l?.runChangesBoundary ??
                'Only files in the workspace come back. Sent mail, web calls '
                    'and changes outside the workspace stay.',
            key: const ValueKey<String>('agents-run-changes-boundary'),
            style: quiet,
          ),
        ),
      ],
    ];
  }

  Widget _timelineHead(BuildContext context, AgentsRunChangesReport report) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations? l = AppLocalizations.of(context);
    final int steps = report.commitsTotal ?? report.commits.length;
    return InkWell(
      key: const ValueKey<String>('agents-run-changes-timeline'),
      onTap: () => setState(() => _timelineOpen = !_timelineOpen),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: <Widget>[
            HugeIcon(
              HugeIcons.clock01,
              size: 20,
              color: theme.colorScheme.onSurface,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                steps == 1
                    ? (l?.runChangesStepsOne ?? '1 step')
                    : (l?.runChangesStepsMany(steps) ?? '$steps steps'),
                style: theme.textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            AnimatedRotation(
              turns: _timelineOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 250),
              child: HugeIcon(
                HugeIcons.arrowDown01,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _footer(BuildContext context, AgentsRunChangesReport? report) {
    if (report == null || report.failure != null) return const <Widget>[];
    final bool anyCheckable = report.files.any(_checkable);
    if (!anyCheckable) return const <Widget>[];
    final ThemeData theme = Theme.of(context);
    final AppLocalizations? l = AppLocalizations.of(context);
    final int count = _checked.length;
    final bool enabled = count > 0 && !_busy && !_running;
    final String? notice = _running
        ? (l?.runChangesWaitAgent ?? 'Wait until the agent is done')
        : _undoError;
    return <Widget>[
      const SizedBox(height: 14),
      if (notice != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
          child: Text(
            notice,
            key: const ValueKey<String>('agents-run-changes-notice'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: _running
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.error,
            ),
          ),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          button: true,
          enabled: enabled,
          child: IgnorePointer(
            ignoring: !enabled,
            child: AnimatedOpacity(
              opacity: enabled ? 1 : 0.38,
              duration: const Duration(milliseconds: 200),
              // The button's label never wraps; on a narrow phone at a
              // large text scale it shrinks instead of running off the edge.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: ExpressiveButton(
                  key: const ValueKey<String>('agents-run-changes-undo'),
                  label: count == 1
                      ? (l?.runChangesUndoOne ?? 'Undo 1 file')
                      : (l?.runChangesUndoMany(count) ?? 'Undo $count files'),
                  onTap: () => _undo(),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.checkable,
    required this.checked,
    required this.onChanged,
  });

  final AgentsRunFile file;
  final bool checkable;
  final bool checked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final HugeIconData icon = switch (file.change) {
      AgentsRunFileChange.added => HugeIcons.add01,
      AgentsRunFileChange.modified => HugeIcons.fileEdit,
      AgentsRunFileChange.deleted => HugeIcons.delete02,
    };
    final String counts = file.binary
        ? (l?.runChangesBinary ?? 'Binary file')
        : _lineCounts(file.additions, file.deletions);
    final AgentsRunConflict? conflict = file.conflict;
    final Color fg = file.undone ? scheme.onSurfaceVariant : scheme.onSurface;
    final ValueChanged<bool>? toggle = checkable ? onChanged : null;
    return InkWell(
      key: ValueKey<String>('agents-run-changes-file-${file.path}'),
      onTap: toggle == null ? null : () => toggle(!checked),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: HugeIcon(icon, size: 20, color: fg),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // The path identifies the file: it wraps, it is never cut.
                  Text(
                    file.path,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w500,
                      decoration: file.undone
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    file.undone
                        ? '$counts · ${l?.runChangesFileUndone ?? 'Undone'}'
                        : counts,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (conflict != null && !file.undone)
                    Text(
                      _conflictText(l, conflict.reason),
                      key: ValueKey<String>(
                        'agents-run-changes-conflict-${file.path}',
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                ],
              ),
            ),
            if (checkable)
              Checkbox(
                key: ValueKey<String>('agents-run-changes-check-${file.path}'),
                value: checked,
                onChanged: toggle == null
                    ? null
                    : (bool? on) => toggle(on ?? false),
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _CommitRow extends StatelessWidget {
  const _CommitRow({required this.commit});

  final AgentsRunCommit commit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final DateTime? time = commit.time;
    final String locale =
        Localizations.maybeLocaleOf(context)?.toLanguageTag() ?? 'en';
    String clock = '';
    if (time != null) {
      try {
        clock = DateFormat.Hm(locale).format(time);
      } catch (_) {
        clock = DateFormat.Hm().format(time);
      }
    }
    return Padding(
      key: ValueKey<String>('agents-run-changes-commit-${commit.commit}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 48,
            child: Text(
              clock,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              commit.subject.isEmpty
                  ? (commit.short ?? commit.commit)
                  : commit.subject,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// "+12 −3": the wire's line counts, a real minus sign.
String _lineCounts(int additions, int deletions) => '+$additions −$deletions';

String _conflictText(AppLocalizations? l, AgentsRunConflictReason reason) =>
    switch (reason) {
      AgentsRunConflictReason.changedLaterByRun =>
        l?.runChangesConflictLater ?? 'Changed later by another run',
      AgentsRunConflictReason.changedOutside =>
        l?.runChangesConflictYou ?? 'Changed by you',
      AgentsRunConflictReason.uncommitted =>
        l?.runChangesConflictUnsaved ?? 'Edited, not saved yet',
    };

/// Why the sheet has no rows to offer (`run_changes.reason`).
String? _reasonText(AppLocalizations? l, String? reason) => switch (reason) {
  'no_history' =>
    l?.runChangesErrNoHistory ??
        'This workspace keeps no history, so there is nothing to undo.',
  'not_found' =>
    l?.runChangesErrNotFound ?? 'Your computer does not know this run.',
  'no_changes' => l?.runChangesErrNoChanges ?? 'This run changed no file.',
  'already_undone' => l?.runChangesAllUndone ?? 'Changes undone',
  'failed' =>
    l?.runChangesErrFailed ?? 'Your computer could not read the changes.',
  _ => null,
};

/// An undo code, or the app's own `not_sent` / `no_answer`, as a sentence.
String _codeText(AppLocalizations? l, String? code) => switch (code) {
  'not_sent' =>
    l?.runChangesErrNotConnected ??
        'Not connected to your computer. Try again when it is back.',
  'no_answer' =>
    l?.runChangesErrNoAnswer ?? 'Your computer did not answer. Try again.',
  'conflicts' =>
    l?.runChangesErrAllConflict ?? 'Every file changed after this run.',
  _ =>
    _reasonText(l, code) ??
        l?.runChangesErrFailed ??
        'Your computer could not read the changes.',
};
