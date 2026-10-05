// lib/widgets/agents_quiet_run_fold.dart
//
// A fired "notify only on change" automation that found nothing new
// (docs/WIRE_CONTRACT.md, "Notify only on change") still writes an answer
// into the coworker's thread. Read in full every time, those answers bury
// the one run that did find something. So such a run folds to one quiet
// line, "No change · <summary>", in the automation wake line's style; a tap
// opens the full answer.
//
// Which runs are quiet is the automations source's to say
// ([AutomationsSource.isQuietRun]); the answer knows its run by the run id
// the thread keeps on it (agents_run_cost.dart, [splitRunMeta]).

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

class AgentsQuietRunFold extends StatefulWidget {
  const AgentsQuietRunFold({
    super.key,
    required this.runId,
    required this.child,
    this.source,
  });

  /// The host's id of the run that wrote this answer.
  final String runId;

  /// The full answer, shown when the run was not quiet or the line is open.
  final Widget child;

  /// Defaults to [AutomationsSource.instance].
  final AutomationsSource? source;

  @override
  State<AgentsQuietRunFold> createState() => _AgentsQuietRunFoldState();
}

class _AgentsQuietRunFoldState extends State<AgentsQuietRunFold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final AutomationsSource source =
        widget.source ?? AutomationsSource.instance;
    return ListenableBuilder(
      listenable: source,
      builder: (BuildContext context, Widget? _) {
        if (!source.isQuietRun(widget.runId)) return widget.child;
        final Widget line = _line(
          context,
          source.quietRunSummary(widget.runId),
        );
        // One shape open or closed, so the line keeps its element and with
        // it the keyboard focus when it is toggled.
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[line, if (_open) widget.child],
        );
      },
    );
  }

  Widget _line(BuildContext context, String? summary) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations? l = AppLocalizations.of(context);
    final Color color = theme.colorScheme.onSurfaceVariant;
    final TextStyle style =
        (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(
          color: color,
        );
    final String noChange = l?.automationNoChange ?? 'No change';
    final String text = summary == null || summary.trim().isEmpty
        ? noChange
        : '$noChange · ${summary.trim()}';
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Semantics(
        button: true,
        expanded: _open,
        hint: l?.automationLastResult ?? 'Last result',
        // An InkWell, not a bare GestureDetector: it takes keyboard focus
        // and opens on Enter / Space like every other button.
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey<String>('agents-quiet-run-line'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  AppIcon(Icons.bolt_outlined, size: 14, color: color),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      text,
                      style: style,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
