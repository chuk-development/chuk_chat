// lib/widgets/agents_plan_review_card.dart
//
// The plan from plan mode, for review (docs/WIRE_CONTRACT.md, "Plan mode"):
// an `approval_request` with action `plan_review`. The plan renders as
// markdown. Approve lets the agent carry it out; Keep planning opens a field
// whose text goes back as `approval_decision.feedback`. The buttons lock
// after the first answer.

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/agent_markdown.dart';

class AgentsPlanReviewCard extends StatefulWidget {
  const AgentsPlanReviewCard({
    super.key,
    required this.request,
    required this.onDecide,
    this.decision,
    this.dense = false,
    this.maxPlanHeight = 320,
  });

  final AgentsRelayApprovalRequest request;

  /// approved true = Approve; false = Keep planning with the optional text.
  final void Function(bool approved, String? feedback) onDecide;

  /// The answer already sent; the buttons are gone then.
  final bool? decision;
  final bool dense;
  final double maxPlanHeight;

  @override
  State<AgentsPlanReviewCard> createState() => _AgentsPlanReviewCardState();
}

class _AgentsPlanReviewCardState extends State<AgentsPlanReviewCard> {
  bool _feedbackOpen = false;
  final TextEditingController _feedback = TextEditingController();

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final AgentsRelayApprovalRequest r = widget.request;
    final bool? picked = widget.decision;
    final bool closed = picked == null && r.isDecided;
    return Semantics(
      container: true,
      liveRegion: true,
      identifier: 'agents-plan-review',
      child: Container(
        key: const ValueKey<String>('agents-plan-review-card'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(kRadiusXxl),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                HugeIcon(
                  HugeIcons.clipboardList,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    r.summary ?? l.agentsPlanReviewTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxPlanHeight),
              child: SingleChildScrollView(
                key: const ValueKey<String>('agents-plan-review-body'),
                child: AgentMarkdown(r.plan ?? '', selectable: false),
              ),
            ),
            const SizedBox(height: 12),
            if (picked != null || closed)
              Row(
                key: const ValueKey<String>('agents-plan-review-decided'),
                children: <Widget>[
                  HugeIcon(
                    picked == true
                        ? HugeIcons.checkmarkCircle02
                        : HugeIcons.pencilEdit02,
                    size: 18,
                    color: picked == true
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      closed
                          ? l.agentsPlanClosed
                          : (picked!
                                ? l.agentsPlanApproved
                                : l.agentsPlanKeptPlanning),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              )
            else if (_feedbackOpen) ...<Widget>[
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(kRadiusMd),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  key: const ValueKey<String>('agents-plan-review-feedback'),
                  controller: _feedback,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 6,
                  maxLength: 4000,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                    hintText: l.agentsPlanFeedbackHint,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ExpressiveButton(
                    key: const ValueKey<String>('agents-plan-review-cancel'),
                    label: l.agentsQuestionBack,
                    tonal: true,
                    dense: widget.dense,
                    onTap: () => setState(() => _feedbackOpen = false),
                  ),
                  ExpressiveButton(
                    key: const ValueKey<String>('agents-plan-review-send'),
                    label: l.agentsPlanSendFeedback,
                    dense: widget.dense,
                    onTap: () => widget.onDecide(false, _feedback.text),
                  ),
                ],
              ),
            ] else
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ExpressiveButton(
                    key: const ValueKey<String>('agents-plan-review-keep'),
                    label: l.agentsPlanKeepPlanning,
                    tonal: true,
                    dense: widget.dense,
                    onTap: () => setState(() => _feedbackOpen = true),
                  ),
                  ExpressiveButton(
                    key: const ValueKey<String>('agents-plan-review-approve'),
                    label: l.agentsPlanApprove,
                    dense: widget.dense,
                    onTap: () => widget.onDecide(true, null),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
