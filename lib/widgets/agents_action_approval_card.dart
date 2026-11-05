// lib/widgets/agents_action_approval_card.dart
//
// "Allow this?" for one outward action of an agent: a mail, a connector
// tool the service marks as destructive, a click or a form in the browser,
// or a publish (docs/WIRE_CONTRACT.md, "Per-action approvals").
//
// The run waits on the host until the user answers. The card sits where the
// run is, at the end of the transcript (like the browser takeover card), and
// offers the answers the host named, in its order: allow once, always for
// this agent, always on this site, deny. A lasting answer is stored on the
// host and applies from the next action.
//
// Two kinds of the agent's own commands have their own body
// (docs/WIRE_CONTRACT.md, "Sandbox escalation" and "Auto review"): a
// `sandbox_escalation` asks to run ONE command with more permissions, an
// `auto_review` card says what the reviewer model thought. Both offer only
// Allow once and Deny.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_command_prefix.dart';
import 'package:chuk_chat/services/agents/agents_draft_history.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/word_diff.dart';
import 'package:chuk_chat/widgets/draft_diff_text.dart';

typedef _Req = AgentsRelayApprovalRequest;

class AgentsActionApprovalCard extends StatelessWidget {
  const AgentsActionApprovalCard({
    super.key,
    required this.request,
    required this.agentName,
    required this.onSelect,
    this.decision,
    this.dense = false,
    this.previousDraft,
    this.keyboardShortcuts = false,
  });

  /// Desktop: Enter allows once, Esc denies, while the card is open and the
  /// focus is in the card (docs/DESIGN.md §14.7). A key typed anywhere
  /// else (the composer, chuk's chat in front of a hidden Agents half)
  /// never answers.
  final bool keyboardShortcuts;

  /// The host's request: the class, the one-line summary, the details and
  /// the answers to offer.
  final AgentsRelayApprovalRequest request;

  /// The agent's name for "Always for (agent)". Empty falls back to
  /// "this agent".
  final String agentName;

  /// Called with the option the user picked (`once`, `always_this_agent`,
  /// `always_this_site` or `deny`).
  final ValueChanged<String> onSelect;

  /// The option already sent. The buttons are gone then and the card says
  /// what the answer covered.
  final String? decision;

  /// Desktop size (docs/DESIGN.md §14.8): the dense buttons.
  final bool dense;

  /// The draft this one revises (bead chuk_chat-gkt9): the previous mail,
  /// or the previous call of the same connector tool, in this thread. When
  /// it is set and the text changed, the card marks what changed.
  final AgentsDraft? previousDraft;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final String name = agentName.trim().isEmpty
        ? (l?.approvalThisAgent ?? 'this agent')
        : agentName.trim();
    final String? picked = decision;
    final bool open = picked == null && !request.isDecided;

    return _ApprovalKeys(
      enabled: keyboardShortcuts && open,
      onAllowOnce: request.options.contains(_Req.scopeOnce)
          ? () => onSelect(_Req.scopeOnce)
          : null,
      onDeny: request.options.contains(_Req.scopeDeny)
          ? () => onSelect(_Req.scopeDeny)
          : null,
      child: Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey<String>('agents-approval-card'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _header(theme, l),
              ..._details(context, theme, l),
              const SizedBox(height: 12),
              if (picked == null && !request.isDecided)
                _buttons(scheme, l, name)
              else if (picked == null)
                // The host closed the request itself (timeout, Stop, or it
                // decided on its own): never offer Allow for it again
                // (docs/WIRE_CONTRACT.md, "Closed by timeout or stop").
                _closed(theme, l)
              else
                _decided(theme, l, name, picked),
              if (open && keyboardShortcuts)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l?.approvalKeysHint ?? 'Enter allows once. Esc denies.',
                    key: const ValueKey<String>('agents-approval-keys-hint'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _header(ThemeData theme, AppLocalizations? l) {
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: HugeIcon(
            _isEscalation
                ? HugeIcons.shieldAlert
                : _iconFor(request.actionClass),
            size: 20,
            color: scheme.onSecondaryContainer,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                // ── own browser ──
                if (inUserBrowser)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      l?.ubApprovalInOwnBrowser ?? 'In your own browser',
                      key: const ValueKey<String>(
                        'agents-approval-own-browser',
                      ),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                // ── end own browser ──
                Text(
                  _title(l),
                  key: const ValueKey<String>('agents-approval-title'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// One block per class, from `details`. Never a typed text, a form value
  /// or a password: the host leaves those out, and nothing here asks for
  /// them.
  List<Widget> _details(
    BuildContext context,
    ThemeData theme,
    AppLocalizations? l,
  ) {
    final Map<String, dynamic> d = request.details ?? const <String, dynamic>{};
    final List<Widget> rows = <Widget>[];
    void field(String label, String? value) {
      if (value == null || value.trim().isEmpty) return;
      rows.add(_Field(label: label, value: value.trim()));
    }

    if (_isEscalation) return _escalationDetails(theme, l, d);
    switch (request.actionClass) {
      case 'local_actions':
        rows.addAll(_localActionRows(theme, l, d));
      case 'send_external':
        if (_text(d['reply_to']) != null) {
          rows.add(
            _Field(label: l?.approvalMailReply ?? 'Reply to a mail', value: ''),
          );
        }
        field(l?.approvalMailTo ?? 'To', _list(d['to']));
        field(l?.approvalMailCc ?? 'Cc', _list(d['cc']));
        final String? subject = _text(d['subject']);
        final String? oldSubject = previousDraft?.subject?.trim();
        if (subject != null &&
            oldSubject != null &&
            oldSubject.isNotEmpty &&
            oldSubject != subject) {
          rows.add(
            _Field(
              label: l?.approvalMailSubject ?? 'Subject',
              value: subject,
              previous: oldSubject,
            ),
          );
        } else {
          field(l?.approvalMailSubject ?? 'Subject', subject);
        }
        field(
          l?.approvalMailAttachments ?? 'Attachments',
          _list(d['attachments'], basename: true),
        );
        final String? preview = _text(d['preview']);
        if (preview != null) {
          rows.add(
            _diffOrQuote(l, previousDraft?.body.trim(), preview, mono: false),
          );
        }
      case 'mcp_destructive':
        field(l?.approvalConnector ?? 'Connector', _text(d['server']));
        field(l?.approvalConnectorTool ?? 'Tool', _text(d['remote_tool']));
        final String? args = _arguments(d['arguments']);
        if (args != null) {
          final String? before = previousDraft == null
              ? null
              : _arguments(previousDraft!.body);
          rows.add(_diffOrQuote(l, before, args, mono: true));
        }
      case 'browser_act':
        field(l?.approvalBrowserSite ?? 'Site', request.site);
        // own browser: the page `browser_navigate` opens.
        field(l?.ubApprovalAddress ?? 'Address', _text(d['url']));
        final String? element = _text(d['element']);
        if (element != null) {
          field(
            l?.approvalBrowserTarget ?? 'Target',
            d['submit'] == true
                ? (l?.approvalBrowserTargetSubmit(element) ??
                      '$element, and submit')
                : element,
          );
        }
        field(l?.approvalBrowserKey ?? 'Key', _text(d['key']));
        field(l?.approvalBrowserFields ?? 'Fields', _list(d['fields']));
        field(
          l?.approvalBrowserFiles ?? 'Files',
          _list(d['files'], basename: true),
        );
      default:
        // A shell command the safety floor stopped: the command itself.
        final String? command = _text(d['command']);
        if (command != null) rows.add(_Quote(text: command, mono: true));
        if (request.action == 'herenow_publish' ||
            request.actionClass == 'publish') {
          final String files = request.fileCount == 1
              ? '1 file'
              : '${request.fileCount} files';
          final String label = request.name.isEmpty
              ? request.path
              : request.name;
          rows.add(
            _Field(
              label: '',
              value:
                  '$label · $files · ${humanApprovalBytes(request.totalBytes)}',
            ),
          );
          if (request.public) {
            rows.add(
              _Field(
                label: '',
                value:
                    l?.approvalPublicSite ??
                    'This site will be public: anyone with the link can '
                        'view it.',
              ),
            );
          }
        }
    }
    if (rows.isEmpty) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.only(left: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        ),
      ),
    ];
  }

  /// The draft text: with its changes marked when it revises [before] and
  /// enough of it stayed to be the same draft, else the plain quote.
  Widget _diffOrQuote(
    AppLocalizations? l,
    String? before,
    String after, {
    required bool mono,
  }) {
    if (before != null && before.isNotEmpty) {
      final List<WordDiffSegment> diff = wordDiff(before, after);
      if (draftDiffWorthShowing(diff)) {
        return _Quote(
          text: after,
          mono: mono,
          diff: diff,
          changedLabel:
              l?.approvalDraftChanged ?? 'Changed since the last draft',
        );
      }
    }
    return _Quote(text: after, mono: mono);
  }

  Widget _buttons(ColorScheme scheme, AppLocalizations? l, String name) {
    // No "Always allow …" without a prefix the app can stand behind (a
    // shell or a wrapper never gets one, see agents_command_prefix.dart).
    final bool prefix = approvalCommandPrefix(request) != null;
    final List<String> options = <String>[
      for (final String o in request.options)
        if ((o != _Req.scopeAlwaysPrefix || prefix) &&
            (!_onceOrDenyOnly || o == _Req.scopeOnce || o == _Req.scopeDeny))
          o,
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (int i = 0; i < options.length; i++)
          // A button never grows wider than the card: on a narrow phone at a
          // large text size it scales down instead of overflowing.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: ExpressiveButton(
              key: ValueKey<String>('agents-approval-option-${options[i]}'),
              label: optionLabel(l, options[i], name),
              // The first answer is the one most people give; the rest are
              // the tonal family, so there is one filled target.
              tonal: i != 0,
              dense: dense,
              onTap: () => onSelect(options[i]),
            ),
          ),
      ],
    );
  }

  Widget _decided(
    ThemeData theme,
    AppLocalizations? l,
    String name,
    String picked,
  ) {
    final ColorScheme scheme = theme.colorScheme;
    final bool denied = picked == _Req.scopeDeny;
    return Row(
      key: const ValueKey<String>('agents-approval-decided'),
      children: <Widget>[
        HugeIcon(
          denied ? HugeIcons.cancel01 : HugeIcons.checkmarkCircle02,
          size: 18,
          color: denied ? scheme.onSurfaceVariant : scheme.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            picked == _Req.scopeAlwaysPrefix
                ? (l?.approvalDecidedAlwaysPrefix(
                        approvalCommandPrefix(request) ?? '',
                      ) ??
                      'Allowed always: ${approvalCommandPrefix(request) ?? ''}')
                : decisionLabel(l, picked, name, request.site),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// The line for a request the host closed without the user's answer.
  Widget _closed(ThemeData theme, AppLocalizations? l) {
    final ColorScheme scheme = theme.colorScheme;
    final bool approved = request.isApproved;
    return Row(
      key: const ValueKey<String>('agents-approval-closed'),
      children: <Widget>[
        HugeIcon(
          approved ? HugeIcons.checkmarkCircle02 : HugeIcons.cancel01,
          size: 18,
          color: approved ? scheme.primary : scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _onceOrDenyOnly && request.isApproved
                ? (l?.approvalDecidedOnce ?? 'Allowed once')
                : closedLabel(l, request),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// What a request the host closed says: "Timed out", "Stopped", or the
  /// plain outcome for any other reason.
  static String closedLabel(
    AppLocalizations? l,
    AgentsRelayApprovalRequest request,
  ) {
    if (request.isApproved) return l?.approvalClosedAllowed ?? 'Allowed';
    return switch (request.decisionReason) {
      'timeout' => l?.approvalClosedTimedOut ?? 'Timed out. Not allowed.',
      'stopped' => l?.approvalClosedStopped ?? 'Stopped. Not allowed.',
      _ => l?.approvalDecidedDenied ?? 'Denied',
    };
  }

  /// The button text of one option, as the contract words it.
  String optionLabel(AppLocalizations? l, String option, String name) {
    final String site = request.site ?? (l?.approvalThisSite ?? 'this site');
    return switch (option) {
      _Req.scopeOnce => l?.approvalAllowOnce ?? 'Allow once',
      _Req.scopeAlwaysAgent =>
        request.actionClass == 'mcp_destructive'
            ? (l?.approvalAlwaysConnector(name) ??
                  'Always allow connector actions for $name')
            : (l?.approvalAlwaysAgent(name) ?? 'Always for $name'),
      _Req.scopeAlwaysSite => l?.approvalAlwaysSite(site) ?? 'Always on $site',
      _Req.scopeAlwaysPrefix => _prefixLabel(l),
      _Req.scopeDeny => l?.approvalDeny ?? 'Deny',
      _ => option,
    };
  }

  /// "Always allow git push": the prefix the host will remember.
  String _prefixLabel(AppLocalizations? l) {
    final String prefix = approvalCommandPrefix(request) ?? '';
    return l?.approvalAlwaysPrefix(prefix) ?? 'Always allow $prefix';
  }

  /// What an answer covered, for the decided line.
  static String decisionLabel(
    AppLocalizations? l,
    String picked,
    String name,
    String? site,
  ) {
    final String where = site ?? (l?.approvalThisSite ?? 'this site');
    return switch (picked) {
      _Req.scopeDeny => l?.approvalDecidedDenied ?? 'Denied',
      _Req.scopeAlwaysAgent =>
        l?.approvalDecidedAlwaysAgent(name) ?? 'Allowed always for $name',
      _Req.scopeAlwaysSite =>
        l?.approvalDecidedAlwaysSite(where) ?? 'Allowed always on $where',
      _ => l?.approvalDecidedOnce ?? 'Allowed once',
    };
  }

  // ── own browser ──
  /// The action runs in the user's own browser (the add-on), not in the
  /// sandbox: `details.browser == "user_browser"`.
  bool get inUserBrowser => request.details?['browser'] == 'user_browser';
  // ── end own browser ──

  // ── esc ──
  /// The approval's kind: `sandbox_escalation`, `auto_review`, or a takeover
  /// kind. `details.kind` first; `fromPayload` keeps the top-level `kind` in
  /// [AgentsRelayApprovalRequest.takeoverKind].
  String? get _kind {
    final Object? kind = request.details?['kind'];
    return kind is String && kind.isNotEmpty ? kind : request.takeoverKind;
  }

  bool get _isEscalation =>
      _kind == 'sandbox_escalation' ||
      request.actionClass == 'sandbox_escalation';

  bool get _isAutoReview => _kind == 'auto_review';

  /// A grant for one call: no "always" on these cards, whatever the host
  /// listed.
  bool get _onceOrDenyOnly => _isEscalation || _isAutoReview;

  String _title(AppLocalizations? l) {
    if (_isEscalation) {
      return l?.escTitle ?? 'Run one command with more permissions';
    }
    final String? summary = request.summary;
    if (summary != null) return summary;
    if (request.actionClass == 'local_actions') {
      return switch (_text(request.details?['local_tool']) ?? request.tool) {
        'python' => l?.localActionScript ?? 'Run this script?',
        'write_file' => l?.localActionWrite ?? 'Write this file?',
        'edit_file' => l?.localActionEdit ?? 'Change this file?',
        'apply_patch' => l?.localActionPatch ?? 'Apply this patch?',
        _ => l?.localActionCommand ?? 'Run this command?',
      };
    }
    return l?.approvalTitleFallback ?? 'Allow this action?';
  }

  /// A withheld permission in words.
  static String permissionLabel(AppLocalizations? l, String name) =>
      switch (name) {
        'network' => l?.escPermNetwork ?? 'Internet',
        'workspace_write' =>
          l?.escPermWorkspaceWrite ?? 'Write to the workspace',
        'sudo' => l?.escPermSudo ?? 'Admin rights (sudo)',
        _ => name,
      };

  List<Widget> _escalationDetails(
    ThemeData theme,
    AppLocalizations? l,
    Map<String, dynamic> d,
  ) {
    final ColorScheme scheme = theme.colorScheme;
    final Object? raw = d['permissions'];
    final List<String> permissions = <String>[
      if (raw is List)
        for (final Object? p in raw)
          if (p is String && p.trim().isNotEmpty) p.trim(),
    ];
    final String? justification = _text(d['justification']);
    final String? command = _text(d['command']);
    return <Widget>[
      const SizedBox(height: 10),
      Padding(
        padding: const EdgeInsets.only(left: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (permissions.isNotEmpty) ...<Widget>[
              Text(
                l?.escNeeds ?? 'Needs',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String p in permissions)
                    Container(
                      key: ValueKey<String>('agents-esc-permission-$p'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(kRadiusSm),
                      ),
                      child: Text(
                        permissionLabel(l, p),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSecondaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (justification != null)
              Container(
                key: const ValueKey<String>('agents-esc-justification'),
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.only(left: 10),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: scheme.outlineVariant, width: 3),
                  ),
                ),
                child: Text(
                  justification,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            if (command != null)
              CollapsibleCodeBlock(
                key: const ValueKey<String>('agents-esc-command'),
                text: command,
              ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                l?.escOneCall ??
                    'Only for this one command. The agent\'s permissions do '
                        'not change.',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  /// The body of a `local_actions` card (mode `ask` or `auto_review`): the
  /// reviewer's line, then the command, script, path or files with a
  /// preview.
  List<Widget> _localActionRows(
    ThemeData theme,
    AppLocalizations? l,
    Map<String, dynamic> d,
  ) {
    final List<Widget> rows = <Widget>[];
    final Object? review = d['review'];
    if (_isAutoReview || review is Map) {
      rows.add(_ReviewLine(text: reviewText(l, review)));
    }
    final String? command = _text(d['command']) ?? _text(d['code']);
    if (command != null) {
      rows.add(
        CollapsibleCodeBlock(
          key: const ValueKey<String>('agents-local-command'),
          text: command,
        ),
      );
    }
    final String? path = _text(d['path']);
    if (path != null) {
      rows.add(_Field(label: l?.localActionFile ?? 'File', value: path));
    }
    final String? files = _list(d['files']);
    if (files != null) {
      rows.add(_Field(label: l?.localActionFiles ?? 'Files', value: files));
    }
    final String? preview = _text(d['preview']);
    if (preview != null) {
      rows.add(
        CollapsibleCodeBlock(
          key: const ValueKey<String>('agents-local-preview'),
          text: preview,
        ),
      );
    }
    final String? description = _text(d['description']);
    if (description != null) {
      rows.add(
        _Field(label: l?.localActionNote ?? 'Note', value: description),
      );
    }
    return rows;
  }

  /// "Reviewer: medium risk — reason", or "The reviewer could not decide".
  static String reviewText(AppLocalizations? l, Object? review) {
    final String invalid = l?.reviewInvalid ?? 'The reviewer could not decide';
    if (review is! Map || review['valid'] == false) return invalid;
    final String? rawRisk = _text(review['risk']);
    if (rawRisk == null) return invalid;
    final String risk = switch (rawRisk) {
      'low' => l?.reviewRiskLow ?? 'low',
      'medium' => l?.reviewRiskMedium ?? 'medium',
      'high' => l?.reviewRiskHigh ?? 'high',
      _ => rawRisk,
    };
    final String? reason = _text(review['reason']);
    if (reason == null) {
      return l?.reviewLineNoReason(risk) ?? 'Reviewer: $risk risk';
    }
    return l?.reviewLine(risk, reason) ?? 'Reviewer: $risk risk — $reason';
  }
  // ── end esc ──

  /// One glyph per class, from the app's own set (docs/DESIGN.md §5).
  static HugeIconData _iconFor(String? actionClass) => switch (actionClass) {
    'send_external' => HugeIcons.mail01,
    'mcp_destructive' => HugeIcons.puzzle,
    'browser_act' => HugeIcons.globe02,
    'publish' => HugeIcons.share08,
    'local_actions' => HugeIcons.terminal,
    _ => HugeIcons.alertCircle,
  };

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String? _list(Object? value, {bool basename = false}) {
    final List<Object?> raw = value is List ? value : <Object?>[value];
    final List<String> items = <String>[
      for (final Object? item in raw)
        if (item is String && item.trim().isNotEmpty)
          basename ? item.trim().split('/').last : item.trim(),
    ];
    return items.isEmpty ? null : items.join(', ');
  }

  /// Connector arguments as the host sent them: compact JSON already, or a
  /// map to encode. Pretty-printed so a reader can scan the keys.
  static String? _arguments(Object? value) {
    if (value == null) return null;
    Object? decoded = value;
    if (value is String) {
      if (value.trim().isEmpty) return null;
      try {
        decoded = jsonDecode(value);
      } catch (_) {
        return value.trim();
      }
    }
    try {
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return '$value';
    }
  }
}

// ── esc ──
/// The reviewer's verdict on an `auto_review` card.
class _ReviewLine extends StatelessWidget {
  const _ReviewLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // One line high, so the glyph sits on the first line of the text.
          SizedBox(
            height: 18,
            child: Center(
              child: HugeIcon(
                HugeIcons.shield01,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              key: const ValueKey<String>('agents-review-line'),
              style: theme.textTheme.bodySmall?.copyWith(
                height: 18 / 12,
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A command or script in a monospace block, cut to [collapsedLines] lines
/// with a "Show all" toggle when it is longer.
class CollapsibleCodeBlock extends StatefulWidget {
  const CollapsibleCodeBlock({
    super.key,
    required this.text,
    this.collapsedLines = 6,
  });

  final String text;
  final int collapsedLines;

  @override
  State<CollapsibleCodeBlock> createState() => _CollapsibleCodeBlockState();
}

class _CollapsibleCodeBlockState extends State<CollapsibleCodeBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final List<String> lines = widget.text.split('\n');
    final bool long = lines.length > widget.collapsedLines;
    final String shown = long && !_expanded
        ? lines.take(widget.collapsedLines).join('\n')
        : widget.text;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kRadiusMd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            shown,
            key: const ValueKey<String>('agents-code-text'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const <String>['Courier'],
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (long)
            InkWell(
              key: const ValueKey<String>('agents-code-toggle'),
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(kRadiusSm),
              child: Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text(
                  _expanded
                      ? (l?.escShowLess ?? 'Show less')
                      : (l?.escShowAll ?? 'Show all'),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.accentForegroundOn(
                      scheme.surfaceContainerHighest,
                    ),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
// ── end esc ──

/// 1024 -> "1.0 KB". A plain binary size, no locale or package dependency.
String humanApprovalBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = <String>['KB', 'MB', 'GB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// "Label  value" on one line; the value wraps under itself.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, this.previous});

  final String label;
  final String value;

  /// The value of the draft this one revises; the changes get marked.
  final String? previous;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? base = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            if (label.isNotEmpty)
              TextSpan(
                text: value.isEmpty ? label : '$label  ',
                style: base?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            if (value.isNotEmpty && previous != null)
              ...draftDiffSpans(
                wordDiff(previous!, value),
                scheme,
                base?.copyWith(color: scheme.onSurface),
              )
            else if (value.isNotEmpty)
              TextSpan(
                text: value,
                style: base?.copyWith(color: scheme.onSurface),
              ),
          ],
        ),
        key: previous == null
            ? null
            : const ValueKey<String>('agents-approval-subject-diff'),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// The mail preview, or the connector arguments in a monospace block.
class _Quote extends StatelessWidget {
  const _Quote({
    required this.text,
    this.mono = false,
    this.diff,
    this.changedLabel,
  });

  final String text;
  final bool mono;

  /// The word diff against the previous draft; null draws [text] plain.
  final List<WordDiffSegment>? diff;

  /// The line over a marked draft ("Changed since the last draft").
  final String? changedLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final List<WordDiffSegment>? segments = diff;
    final TextStyle? style =
        (mono
                ? theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontFamilyFallback: const <String>['Courier'],
                  )
                : theme.textTheme.bodySmall)
            ?.copyWith(color: scheme.onSurfaceVariant);
    if (segments != null) {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              key: const ValueKey<String>('agents-approval-draft-changed'),
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                HugeIcon(
                  HugeIcons.edit02,
                  size: 14,
                  color: theme.accentForegroundOn(
                    scheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    changedLabel ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.accentForegroundOn(
                        scheme.surfaceContainerHighest,
                      ),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(children: draftDiffSpans(segments, scheme, style)),
              key: ValueKey<String>(
                mono ? 'agents-approval-args-diff' : 'agents-approval-diff',
              ),
              // The changes are the point: more room than a plain preview.
              maxLines: mono ? 14 : 10,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        key: ValueKey<String>(
          mono ? 'agents-approval-args' : 'agents-approval-preview',
        ),
        maxLines: mono ? 10 : 4,
        overflow: TextOverflow.ellipsis,
        style:
            (mono
                    ? theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontFamilyFallback: const <String>['Courier'],
                      )
                    : theme.textTheme.bodySmall)
                ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Enter = allow once, Esc = deny, while [enabled] and the focus is in the
/// card (scoped like the question card's keys, never a global keyboard
/// handler: a key typed anywhere else, or with the Agents half hidden
/// behind chuk's chat, must not answer an approval). The card takes the
/// focus when it appears and nothing else in its scope holds it; a hidden
/// half sits under `ExcludeFocus`, so it never can.
class _ApprovalKeys extends StatelessWidget {
  const _ApprovalKeys({
    required this.enabled,
    required this.child,
    this.onAllowOnce,
    this.onDeny,
  });

  final bool enabled;
  final VoidCallback? onAllowOnce;
  final VoidCallback? onDeny;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final VoidCallback? allow = onAllowOnce;
    final VoidCallback? deny = onDeny;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        if (allow != null) ...<ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): allow,
          const SingleActivator(LogicalKeyboardKey.numpadEnter): allow,
        },
        const SingleActivator(LogicalKeyboardKey.escape): ?deny,
      },
      child: Focus(
        key: const ValueKey<String>('agents-approval-keys'),
        autofocus: true,
        child: child,
      ),
    );
  }
}
