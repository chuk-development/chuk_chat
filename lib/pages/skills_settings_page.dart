import 'package:flutter/material.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/services/skills/cowork_skill.dart';
import 'package:cowork/services/skills/skills_source.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// The host's skills, one switch each (docs/WIRE_CONTRACT.md, "Skills").
///
/// Nothing here is compiled into the app and nothing is edited here: the host
/// is the truth for which skills exist. The list comes from the host
/// (`skills_list`) when the page opens and on refresh; a switch sends
/// `skill_control`, and the host's reply redraws the row. A skill switched
/// off stays on the host but the coworker does not get it from its next task
/// on.
class SkillsSettingsPage extends StatefulWidget {
  const SkillsSettingsPage({super.key, SkillsSource? source})
      : _injectedSource = source;

  final SkillsSource? _injectedSource;

  @override
  State<SkillsSettingsPage> createState() => _SkillsSettingsPageState();
}

class _SkillsSettingsPageState extends State<SkillsSettingsPage> {
  late final SkillsSource _source =
      widget._injectedSource ?? SkillsSource.instance;

  bool _refreshing = false;
  bool _offline = false;

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

  Future<void> _toggle(CoworkSkill skill, bool enabled) async {
    final sent = await _source.setEnabled(skill.name, enabled);
    if (!mounted || sent) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Not connected to the host')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final title = l?.skills ?? 'Skills';
    final builtin = _source.builtin;
    final workspace = _source.workspace;
    final errors = _source.errors;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        centerTitle: false,
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
            ExpressiveTitle(
              title,
              subtitle:
                  l?.skillsSubtitle ?? 'Procedures the coworker loads on demand',
            ),
            ExpressiveInfoCard(
              text: l?.skillsExplainer ??
                  'A skill is a procedure the coworker loads when it needs '
                      'it. Only its name and description are in every prompt; '
                      'the full instructions load on use.',
            ),
            if (_offline) ...[
              const SizedBox(height: 12),
              const ExpressiveInfoCard(
                text: 'Not connected to the host. The list shows what this '
                    'app last heard; connect to refresh or change anything.',
              ),
            ],
            for (final error in errors) ...[
              const SizedBox(height: 12),
              ExpressiveInfoCard(
                text: error,
                icon: Icons.error_outline,
                tone: theme.colorScheme.errorContainer,
              ),
            ],
            if (_source.all.isEmpty && !_refreshing)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  _source.listed
                      ? 'The host has no skills. Put a SKILL.md into the '
                          'workspace\'s skills folder and refresh.'
                      : 'Waiting for the host…',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            if (builtin.isNotEmpty) ...[
              ExpressiveSectionHeader(l?.skillsBuiltin ?? 'Built in'),
              ExpressiveGroup(
                children: [
                  for (final skill in builtin) _row(skill),
                ],
              ),
            ],
            if (workspace.isNotEmpty) ...[
              const ExpressiveSectionHeader('Workspace'),
              ExpressiveGroup(
                children: [
                  for (final skill in workspace) _row(skill),
                ],
              ),
            ],
            const SizedBox(height: 8),
            const ExpressiveInfoCard(
              text: 'Switching a skill off keeps it on the host; the coworker '
                  'stops getting it from its next task on. Built-in skills '
                  'ship with CoWork, workspace skills are the ones your '
                  'coworker or you put into the workspace.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(CoworkSkill skill) => ExpressiveSwitchRow(
        key: ValueKey<String>('skill-${skill.name}'),
        title: skill.name,
        subtitle: skill.description.isEmpty ? null : skill.description,
        icon: skill.isBuiltin ? Icons.verified_outlined : Icons.folder_outlined,
        value: skill.enabled,
        onChanged: (value) => _toggle(skill, value),
      );
}
