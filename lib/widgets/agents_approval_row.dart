// lib/widgets/agents_approval_row.dart
//
// An answered approval, as it stays in the transcript (bead chuk_chat-aupy):
// one small row with a check, "Approved: <what>", and Undo when the answer is
// stored on the host ("always for this agent", "always on this site").
// Undo takes the permission back out of the agent's policy
// (`AgentsApprovalGrants`); the row then says "Revoked".
//
// The row reads the transcript line (`ask_user` with `decision`), which the
// host keeps and replays, so it survives a reload of the thread. Whether it
// was revoked is kept on this device.

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_approval_grants.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/app_notification.dart';

class AgentsApprovalRow extends StatefulWidget {
  const AgentsApprovalRow({
    super.key,
    required this.grant,
    required this.threadKey,
    this.grants,
  });

  final AgentsApprovalGrant grant;

  /// The thread the approval was given in; it names the agent.
  final String threadKey;

  /// Injectable for tests; default the process-wide one.
  final AgentsApprovalGrants? grants;

  @override
  State<AgentsApprovalRow> createState() => _AgentsApprovalRowState();
}

class _AgentsApprovalRowState extends State<AgentsApprovalRow> {
  AgentsApprovalGrants get _grants =>
      widget.grants ?? AgentsApprovalGrants.instance;

  @override
  void initState() {
    super.initState();
    _grants.addListener(_repaint);
    _grants.load();
  }

  @override
  void didUpdateWidget(AgentsApprovalRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.grants != widget.grants) {
      (oldWidget.grants ?? AgentsApprovalGrants.instance).removeListener(
        _repaint,
      );
      _grants.addListener(_repaint);
    }
  }

  @override
  void dispose() {
    _grants.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  Future<void> _undo() async {
    final bool sent = await _grants.revoke(
      widget.grant,
      threadKey: widget.threadKey,
    );
    if (sent || !mounted) return;
    AppNotifications.show(
      context,
      AppLocalizations.of(context)?.approvalRowUndoFailed ??
          'Could not revoke it. Check that your computer is connected.',
      duration: const Duration(seconds: 3),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final AgentsApprovalGrant grant = widget.grant;
    final bool revoked = _grants.isRevoked(grant.approvalId);
    final bool busy = _grants.isBusy(grant.approvalId);

    final String what = grant.what;
    final String text = revoked
        ? (l?.approvalRowRevoked(what) ?? 'Revoked: $what')
        : grant.approved
        ? (l?.approvalRowApproved(what) ?? 'Approved: $what')
        : (l?.approvalRowDenied(what) ?? 'Denied: $what');
    final bool showAlways = grant.isLasting && !revoked;
    final String always = l?.approvalRowAlways ?? 'always';

    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
      height: 1.3,
    );
    final bool positive = grant.approved && !revoked;

    return Semantics(
      container: true,
      child: Container(
        key: ValueKey<String>('agents-approval-row-${grant.approvalId}'),
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        constraints: const BoxConstraints(minHeight: 36),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            HugeIcon(
              positive ? HugeIcons.checkmarkCircle02 : HugeIcons.cancel01,
              key: const ValueKey<String>('agents-approval-row-icon'),
              size: 16,
              color: positive ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(text: text),
                    if (showAlways)
                      TextSpan(
                        text: ' · $always',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                  ],
                ),
                key: const ValueKey<String>('agents-approval-row-text'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            if (showAlways) ...<Widget>[
              const SizedBox(width: 6),
              MorphTap(
                key: const ValueKey<String>('agents-approval-row-undo'),
                onTap: busy ? null : _undo,
                color: scheme.secondaryContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  l?.approvalRowUndo ?? 'Undo',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ] else
              const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }
}
