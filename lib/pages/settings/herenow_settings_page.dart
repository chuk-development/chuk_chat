import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/services/herenow/herenow_store.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// The here.now publishing connector: let a coworker put a file or a folder on
/// the public web and hand back a live URL. Off by default — while it is off,
/// the agent has no publish tool at all. When on, the approval mode decides
/// whether each public publish waits for a tap (`Ask`) or goes straight out
/// (`Auto`).
///
/// Config lives in SharedPreferences (`herenow_connector_v1`); nothing here is
/// secret. The agent-side gate is enforced host-side — this screen only sets
/// what Agents forwards on the task frame.
class HereNowSettingsPage extends StatefulWidget {
  const HereNowSettingsPage({super.key, HereNowStore? store})
    : _injectedStore = store;

  final HereNowStore? _injectedStore;

  @override
  State<HereNowSettingsPage> createState() => _HereNowSettingsPageState();
}

class _HereNowSettingsPageState extends State<HereNowSettingsPage> {
  late final HereNowStore _store = widget._injectedStore ?? HereNowStore();

  HereNowSettings _settings = const HereNowSettings();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final settings = await _store.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _loading = false;
    });
  }

  Future<void> _update(HereNowSettings next) async {
    setState(() => _settings = next);
    await _store.save(next);
  }

  @override
  Widget build(BuildContext context) {
    return ExpressiveScreen(
      title: 'here.now Publishing',
      builder: (BuildContext context) => _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.paddingOf(context).top + 8,
                16,
                MediaQuery.paddingOf(context).bottom + 32,
              ),
              children: [
                const ExpressiveTitle(
                  'here.now Publishing',
                  subtitle: 'Let a coworker publish files to a live public URL',
                ),
                const ExpressiveSectionHeader('Connector'),
                ExpressiveGroup(
                  children: [
                    ExpressiveSwitchRow(
                      icon: Icons.public,
                      title: 'Enable here.now',
                      subtitle: _settings.enabled
                          ? 'The agent can publish to here.now'
                          : 'The agent has no publish tool',
                      value: _settings.enabled,
                      onChanged: (on) =>
                          _update(_settings.copyWith(enabled: on)),
                    ),
                  ],
                ),
                if (_settings.enabled) ...[
                  const ExpressiveSectionHeader('Before a publish'),
                  ExpressiveGroup(
                    children: [
                      ExpressiveCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Approval',
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            const SizedBox(height: 8),
                            SegmentedButton<HereNowApproval>(
                              segments: const <ButtonSegment<HereNowApproval>>[
                                ButtonSegment<HereNowApproval>(
                                  value: HereNowApproval.ask,
                                  icon: AppIcon(Icons.verified_user_outlined),
                                  label: Text('Ask each time'),
                                ),
                                ButtonSegment<HereNowApproval>(
                                  value: HereNowApproval.auto,
                                  icon: AppIcon(Icons.bolt_outlined),
                                  label: Text('Auto-approve'),
                                ),
                              ],
                              selected: <HereNowApproval>{_settings.approval},
                              onSelectionChanged: (set) => _update(
                                _settings.copyWith(approval: set.first),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _settings.approval == HereNowApproval.ask
                                  ? 'You approve each publish in the chat before '
                                        'anything goes public.'
                                  : 'Publishes go out without asking. The agent '
                                        'does not wait for you.',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                const ExpressiveInfoCard(
                  text:
                      'Published sites are PUBLIC: anyone with the link can view '
                      'them. On the free tier a site is anonymous and expires 24 '
                      'hours after publishing; the agent shares a claim link so '
                      'you can keep it permanently.',
                ),
              ],
            ),
    );
  }
}
