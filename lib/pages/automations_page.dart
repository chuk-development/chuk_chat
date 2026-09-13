import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/widgets/automation_card.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

/// Every automation of the host, grouped by the coworker that owns it, with
/// Pause / Resume / Cancel. The user manages all of them here; an agent only
/// ever sees its own through its tools.
///
/// The list comes from the host (`automation_list`) when the page opens and on
/// pull-to-refresh; every `automation` event updates a row live. The page
/// carries the same shape as the other settings pages: one heading (the app
/// bar's), one explanation, then groups of equal rows.
class AutomationsPage extends StatefulWidget {
  const AutomationsPage({
    super.key,
    AutomationsSource? source,
    this.sessionKey,
    this.chatName,
  }) : _injectedSource = source;

  final AutomationsSource? _injectedSource;

  /// Null is the global account view; chat settings always supply a scope.
  final String? sessionKey;
  final String? chatName;

  @override
  State<AutomationsPage> createState() => _AutomationsPageState();
}

class _AutomationsPageState extends State<AutomationsPage> {
  late final AutomationsSource _source =
      widget._injectedSource ?? AutomationsSource.instance;

  bool _refreshing = false;
  bool _offline = false;
  bool _showFinished = false;

  @override
  void initState() {
    super.initState();
    _source.attach();
    _source.addListener(_onChanged);
    _refresh();
  }

  @override
  void dispose() {
    _source.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    final sent = await _source.refresh(sessionKey: widget.sessionKey);
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _offline = !sent;
    });
  }

  Future<void> _control(AgentsAutomation a, String action) async {
    final sent = await _source.control(a.id, action);
    if (!mounted || sent) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Not connected to the host')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // One row per automation. A restarted watcher leaves its old row behind,
    // and showing both is what made the same automation read as two.
    final all = _source.distinct
        .where(
          (a) => widget.sessionKey == null || a.sessionKey == widget.sessionKey,
        )
        .toList();
    final finished = all.where((a) => a.isOver).toList();
    final shown = _showFinished ? all : all.where((a) => !a.isOver).toList();
    final groups = <String, List<AgentsAutomation>>{};
    for (final a in shown) {
      groups.putIfAbsent(a.sessionKey, () => <AgentsAutomation>[]).add(a);
    }
    return ExpressiveScreen(
      // The bar carries the name of the page. Repeating it as a heading in
      // the body says the same thing twice.
      title: 'Automations',
      actions: <Widget>[
        ExpressiveIconButton(
          hugeIcon: HugeIcons.refresh,
          tooltip: 'Refresh',
          onTap: _refreshing ? null : _refresh,
        ),
      ],
      builder: (BuildContext context) => RefreshIndicator(
        onRefresh: _refresh,
        // The house scroll container for a settings page: it lays every row
        // out up front, so the scrollbar does not resize while you scroll.
        child: SettingsListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + 12,
            16,
            MediaQuery.paddingOf(context).bottom + 32,
          ),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ExpressiveInfoCard(
              icon: Icons.schedule,
              text: widget.sessionKey != null
                  ? 'Schedules and watchers for ${widget.chatName ?? 'this chat'}. '
                        'Ask this coworker to schedule a task or watch something. '
                        'Automations from other chats are not shown here.'
                  : 'A schedule starts a task in its coworker\'s thread when '
                        'it is due. A watcher is a script that runs in the sandbox '
                        'and wakes its coworker only when it sees something change. '
                        'Every row below says which of the two it is, and every '
                        'task it starts ends with a notification.',
            ),
            if (_offline) ...[
              const SizedBox(height: 12),
              const ExpressiveInfoCard(
                icon: Icons.cloud_off_outlined,
                text:
                    'Not connected to the host. The list shows what this '
                    'app last heard; connect to refresh or change anything.',
              ),
            ],
            if (shown.isEmpty && !_refreshing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  _source.listed(widget.sessionKey)
                      ? 'No automations. Ask a coworker to schedule a task '
                            'or to watch something for you.'
                      : 'Waiting for the host…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final entry in groups.entries) ...[
              ExpressiveSectionHeader(_source.coworkerName(entry.key)),
              ExpressiveGroup(
                children: [
                  for (final a in entry.value)
                    AutomationCard(
                      key: ValueKey<String>('automation-${a.id}'),
                      automation: a,
                      onPause: () => _control(a, 'pause'),
                      onResume: () => _control(a, 'resume'),
                      onCancel: () => _control(a, 'cancel'),
                    ),
                ],
              ),
            ],
            if (finished.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Center(
                  child: TextButton.icon(
                    onPressed: () =>
                        setState(() => _showFinished = !_showFinished),
                    icon: AppIcon(
                      _showFinished ? Icons.expand_less : Icons.expand_more,
                    ),
                    label: Text(
                      _showFinished
                          ? 'Hide finished'
                          : 'Show ${finished.length} finished',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
