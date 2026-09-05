import 'package:flutter/material.dart';

import 'package:cowork/services/automations/automations_source.dart';
import 'package:cowork/services/automations/cowork_automation.dart';
import 'package:cowork/widgets/automation_card.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// Every automation of the host, grouped by the coworker (session) that owns
/// it, with Pause / Resume / Cancel. The user manages all of them here; an
/// agent only ever sees its own through its tools.
///
/// The list comes from the host (`automation_list`) when the page opens and
/// on pull-to-refresh; every `automation` event updates a row live.
class AutomationsPage extends StatefulWidget {
  const AutomationsPage({super.key, AutomationsSource? source})
      : _injectedSource = source;

  final AutomationsSource? _injectedSource;

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
    final sent = await _source.refresh();
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _offline = !sent;
    });
  }

  Future<void> _control(CoworkAutomation a, String action) async {
    final sent = await _source.control(a.id, action);
    if (!mounted || sent) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not connected to the host')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = _source.all;
    final shown = _showFinished ? all : all.where((a) => !a.isOver).toList();
    final groups = <String, List<CoworkAutomation>>{};
    for (final a in shown) {
      groups.putIfAbsent(a.sessionKey, () => <CoworkAutomation>[]).add(a);
    }
    final finished = all.where((a) => a.isOver).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Automations'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refreshing ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const ExpressiveTitle(
              'Automations',
              subtitle: 'Schedules and watchers your coworkers set up',
            ),
            if (_offline)
              const ExpressiveInfoCard(
                text: 'Not connected to the host. The list shows what this '
                    'app last heard; connect to refresh or change anything.',
              ),
            if (shown.isEmpty && !_refreshing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  _source.listed(null)
                      ? 'No automations. Ask a coworker to schedule a task '
                          'or to watch something for you.'
                      : 'Waiting for the host…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            for (final entry in groups.entries) ...[
              ExpressiveSectionHeader(_sessionLabel(entry.key)),
              for (final a in entry.value)
                AutomationCard(
                  key: ValueKey<String>('automation-${a.id}'),
                  automation: a,
                  onPause: () => _control(a, 'pause'),
                  onResume: () => _control(a, 'resume'),
                  onCancel: () => _control(a, 'cancel'),
                ),
            ],
            if (finished > 0)
              TextButton.icon(
                onPressed: () => setState(() => _showFinished = !_showFinished),
                icon: Icon(
                  _showFinished ? Icons.expand_less : Icons.expand_more,
                ),
                label: Text(
                  _showFinished
                      ? 'Hide finished'
                      : 'Show $finished finished',
                ),
              ),
            const SizedBox(height: 8),
            const ExpressiveInfoCard(
              text: 'A schedule starts a task in its coworker\'s thread when it '
                  'is due. A watcher is a script that runs in the sandbox and '
                  'wakes the coworker only when something changed. Every fired '
                  'task ends with a notification.',
            ),
          ],
        ),
      ),
    );
  }

  static String _sessionLabel(String sessionKey) {
    if (sessionKey == 'default') return 'Default coworker';
    return sessionKey;
  }
}
