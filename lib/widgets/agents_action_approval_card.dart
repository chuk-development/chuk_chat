// lib/widgets/agents_action_approval_card.dart
//
// "Allow this?" for one outward action of a coworker: a mail, a connector
// tool the service marks as destructive, a click or a form in the browser,
// or a publish (docs/WIRE_CONTRACT.md, "Per-action approvals").
//
// The run waits on the host until the user answers. The card sits where the
// run is, at the end of the transcript (like the browser takeover card), and
// offers the answers the host named, in its order: allow once, always for
// this coworker, always on this site, deny. A lasting answer is stored on the
// host and applies from the next action.

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

typedef _Req = AgentsRelayApprovalRequest;

class AgentsActionApprovalCard extends StatelessWidget {
  const AgentsActionApprovalCard({
    super.key,
    required this.request,
    required this.coworkerName,
    required this.onSelect,
    this.decision,
    this.dense = false,
  });

  /// The host's request: the class, the one-line summary, the details and
  /// the answers to offer.
  final AgentsRelayApprovalRequest request;

  /// The coworker's name for "Always for (coworker)". Empty falls back to
  /// "this coworker".
  final String coworkerName;

  /// Called with the option the user picked (`once`, `always_this_agent`,
  /// `always_this_site` or `deny`).
  final ValueChanged<String> onSelect;

  /// The option already sent. The buttons are gone then and the card says
  /// what the answer covered.
  final String? decision;

  /// Desktop size (docs/DESIGN.md §14.8): the dense buttons.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final String name = coworkerName.trim().isEmpty
        ? (l?.approvalThisCoworker ?? 'this coworker')
        : coworkerName.trim();
    final String? picked = decision;

    return Semantics(
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
              if (picked == null)
                _buttons(scheme, l, name)
              else
                _decided(theme, l, name, picked),
            ],
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
            _iconFor(request.actionClass),
            size: 20,
            color: scheme.onSecondaryContainer,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(
              request.summary ??
                  l?.approvalTitleFallback ??
                  'Allow this action?',
              key: const ValueKey<String>('agents-approval-title'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
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

    switch (request.actionClass) {
      case 'send_external':
        if (_text(d['reply_to']) != null) {
          rows.add(
            _Field(label: l?.approvalMailReply ?? 'Reply to a mail', value: ''),
          );
        }
        field(l?.approvalMailTo ?? 'To', _list(d['to']));
        field(l?.approvalMailCc ?? 'Cc', _list(d['cc']));
        field(l?.approvalMailSubject ?? 'Subject', _text(d['subject']));
        field(
          l?.approvalMailAttachments ?? 'Attachments',
          _list(d['attachments'], basename: true),
        );
        final String? preview = _text(d['preview']);
        if (preview != null) rows.add(_Quote(text: preview));
      case 'mcp_destructive':
        field(l?.approvalConnector ?? 'Connector', _text(d['server']));
        field(l?.approvalConnectorTool ?? 'Tool', _text(d['remote_tool']));
        final String? args = _arguments(d['arguments']);
        if (args != null) rows.add(_Quote(text: args, mono: true));
      case 'browser_act':
        field(l?.approvalBrowserSite ?? 'Site', request.site);
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

  Widget _buttons(ColorScheme scheme, AppLocalizations? l, String name) {
    final List<String> options = request.options;
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
            decisionLabel(l, picked, name, request.site),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
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
      _Req.scopeDeny => l?.approvalDeny ?? 'Deny',
      _ => option,
    };
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

  /// One glyph per class, from the app's own set (docs/DESIGN.md §5).
  static HugeIconData _iconFor(String? actionClass) => switch (actionClass) {
    'send_external' => HugeIcons.mail01,
    'mcp_destructive' => HugeIcons.puzzle,
    'browser_act' => HugeIcons.globe02,
    'publish' => HugeIcons.share08,
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
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

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
            if (value.isNotEmpty)
              TextSpan(
                text: value,
                style: base?.copyWith(color: scheme.onSurface),
              ),
          ],
        ),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// The mail preview, or the connector arguments in a monospace block.
class _Quote extends StatelessWidget {
  const _Quote({required this.text, this.mono = false});

  final String text;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
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
