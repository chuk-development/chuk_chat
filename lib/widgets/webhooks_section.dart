/// The user's server webhooks on the Automations page (docs/WIRE_CONTRACT.md,
/// "Inbound webhooks", App work 6): one row per webhook with its task, the
/// first characters of its secret id, the last call, an on/off switch and
/// delete.
///
/// Off turns the server webhook off (`PATCH enabled`) and pauses its
/// automation; on does the reverse. Delete cancels the automation, then
/// deletes the server webhook. The URL is never shown here: the server
/// returns it only once, when it is made.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_webhooks_service.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class WebhooksSection extends StatefulWidget {
  const WebhooksSection({
    super.key,
    this.sessionKey,
    this.service,
    this.source,
  });

  /// Only the webhooks of this thread's agent; null shows all of them.
  final String? sessionKey;
  final AgentsWebhooksService? service;
  final AutomationsSource? source;

  @override
  State<WebhooksSection> createState() => WebhooksSectionState();
}

class WebhooksSectionState extends State<WebhooksSection> {
  AgentsWebhooksService get _service =>
      widget.service ?? AgentsWebhooksService.instance;
  AutomationsSource get _source => widget.source ?? AutomationsSource.instance;

  List<AgentsWebhook> _hooks = const <AgentsWebhook>[];
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _source.addListener(_changed);
    unawaited(reload());
  }

  @override
  void dispose() {
    _source.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Reads the list again. A failure keeps what is shown.
  Future<void> reload() async {
    try {
      final List<AgentsWebhook> hooks = await _service.list();
      if (mounted) setState(() => _hooks = hooks);
    } on AgentsWebhookException {
      // Signed out or offline: nothing to show, nothing to say.
    }
  }

  /// The live automation that this server webhook starts, when the app
  /// knows it.
  AgentsAutomation? _automationOf(AgentsWebhook hook) {
    for (final AgentsAutomation a in _source.all) {
      if (a.isWebhook && !a.isOver && a.webhookId?.toLowerCase() == hook.id) {
        return a;
      }
    }
    return null;
  }

  bool _inScope(AgentsWebhook hook) {
    final String? session = widget.sessionKey;
    if (session == null) return true;
    final AgentsAutomation? a = _automationOf(hook);
    if (a != null) return a.sessionKey == session;
    return hook.agentId != null && hook.agentId == webhookAgentIdFor(session);
  }

  Future<void> _setEnabled(AgentsWebhook hook, bool enabled) async {
    if (!_busy.add(hook.id)) return;
    setState(() {});
    final AppLocalizations l = _l10n(context);
    try {
      final AgentsWebhook saved = await _service.setEnabled(hook.id, enabled);
      final AgentsAutomation? a = _automationOf(hook);
      if (a != null) {
        if (!enabled && a.isActive) await _source.control(a.id, 'pause');
        if (enabled && a.isPaused) await _source.control(a.id, 'resume');
      }
      if (!mounted) return;
      setState(() {
        _hooks = <AgentsWebhook>[
          for (final AgentsWebhook h in _hooks) h.id == hook.id ? saved : h,
        ];
      });
    } on AgentsWebhookException {
      if (mounted) pillToast(context, l.webhookFailed);
    } finally {
      _busy.remove(hook.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(AgentsWebhook hook) async {
    final AppLocalizations l = _l10n(context);
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(l.webhookDeleteTitle),
        content: Text(l.webhookDeleteBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.webhookCancel),
          ),
          FilledButton(
            key: const ValueKey<String>('webhook-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.webhookDelete),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    if (!_busy.add(hook.id)) return;
    setState(() {});
    try {
      final AgentsAutomation? a = _automationOf(hook);
      if (a != null) await _source.control(a.id, 'cancel');
      await _service.delete(hook.id);
      if (!mounted) return;
      setState(() {
        _hooks = <AgentsWebhook>[
          for (final AgentsWebhook h in _hooks)
            if (h.id != hook.id) h,
        ];
      });
    } on AgentsWebhookException {
      if (mounted) pillToast(context, l.webhookFailed);
    } finally {
      _busy.remove(hook.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = _l10n(context);
    final List<AgentsWebhook> shown = <AgentsWebhook>[
      for (final AgentsWebhook h in _hooks)
        if (_inScope(h)) h,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const ValueKey<String>('webhooks-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ExpressiveSectionHeader(l.webhookListTitle),
        ExpressiveGroup(
          children: <Widget>[
            for (final AgentsWebhook hook in shown) _row(context, l, hook),
          ],
        ),
      ],
    );
  }

  Widget _row(BuildContext context, AppLocalizations l, AgentsWebhook hook) {
    final AgentsAutomation? a = _automationOf(hook);
    final DateTime? last = hook.lastHitAt;
    final String facts = <String>[
      if (hook.secretPrefix case final String prefix) '$prefix…',
      if (last != null) l.webhookLastCall(_stamp(last)) else l.webhookNoCalls,
      if (a != null && a.webhookSigned) l.webhookSecretSet,
    ].join(' · ');
    final bool busy = _busy.contains(hook.id);
    return ExpressiveRow(
      key: ValueKey<String>('webhook-row-${hook.id}'),
      icon: Icons.link,
      title: a?.name ?? l.webhookNoAutomation,
      subtitle: facts,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Switch(
            key: ValueKey<String>('webhook-enabled-${hook.id}'),
            value: hook.enabled,
            onChanged: busy ? null : (bool v) => _setEnabled(hook, v),
          ),
          ExpressiveIconButton(
            key: ValueKey<String>('webhook-delete-${hook.id}'),
            hugeIcon: HugeIcons.delete02,
            size: 40,
            color: Colors.transparent,
            onColor: Theme.of(context).colorScheme.onSurfaceVariant,
            tooltip: l.webhookDelete,
            onTap: busy ? null : () => _delete(hook),
          ),
        ],
      ),
    );
  }

  static String _stamp(DateTime when) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)} '
        '${two(when.hour)}:${two(when.minute)}';
  }
}

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
