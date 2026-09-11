import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/expressive_screen.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/services/skills/cowork_skill.dart';
import 'package:cowork/services/skills/skills_source.dart';
import 'package:cowork/widgets/expressive_settings.dart';
import 'package:cowork/widgets/settings_list_view.dart';

/// The host's skills, one switch each (docs/WIRE_CONTRACT.md, "Skills").
///
/// Nothing here is compiled into the app and nothing is edited here: the host
/// is the truth for which skills exist. The list comes from the host
/// (`skills_list`) when the page opens and on refresh; a switch sends
/// `skill_control`, and the host's reply redraws the row. A skill switched
/// off stays on the host but the coworker does not get it from its next task
/// on.
///
/// The two sections are the host's `source` field, never a name this page
/// knows: `builtin` is a skill that documents CoWork's own machinery and ships
/// with the app (the repository's `skills/builtin/`), `workspace` is any other
/// file under the coworker's `skills/` — including the ones seeded from
/// `skills/workspace/`, which belong to the coworker from the first minute.
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Not connected to the host')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final title = l?.skills ?? 'Skills';
    final builtin = _source.builtin;
    final workspace = _source.workspace;
    final errors = _source.errors;

    return ExpressiveScreen(
      title: title,
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
        // out up front, so the scrollbar does not resize while you scroll —
        // and the second section exists even before you reach it.
        child: SettingsListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + 8,
            16,
            MediaQuery.paddingOf(context).bottom + 32,
          ),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ExpressiveTitle(
              title,
              subtitle:
                  l?.skillsSubtitle ??
                  'Procedures the coworker loads on demand',
            ),
            ExpressiveInfoCard(
              text:
                  l?.skillsExplainer ??
                  'A skill is a procedure the coworker loads when it needs '
                      'it. Only its name and description are in every prompt; '
                      'the full instructions load on use.',
            ),
            if (_offline) ...[
              const SizedBox(height: 12),
              const ExpressiveInfoCard(
                text:
                    'Not connected to the host. The list shows what this '
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
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (builtin.isNotEmpty) ...[
              ExpressiveSectionHeader(l?.skillsBuiltin ?? 'Built in'),
              const ExpressiveInfoCard(
                icon: Icons.verified_outlined,
                text:
                    'The CoWork host\'s own. Each one explains a part of '
                    'the app the coworker works with — schedules, the secrets '
                    'vault, the sandbox terminal, the workspace itself. They '
                    'ship with the host and come back with every update.',
              ),
              const SizedBox(height: 10),
              ExpressiveGroup(
                children: [for (final skill in builtin) _row(skill)],
              ),
            ],
            if (workspace.isNotEmpty) ...[
              const ExpressiveSectionHeader('Workspace'),
              const ExpressiveInfoCard(
                icon: Icons.folder_outlined,
                text:
                    'Files in the coworker\'s workspace, under skills/. Your '
                    'coworker or you put them there, and either of you can '
                    'edit or delete them. A few come with a new workspace to '
                    'start you off — those are yours too.',
              ),
              const SizedBox(height: 10),
              ExpressiveGroup(
                children: [for (final skill in workspace) _row(skill)],
              ),
            ],
            const SizedBox(height: 8),
            const ExpressiveInfoCard(
              text:
                  'Switching a skill off keeps the file where it is; the '
                  'coworker stops getting it from its next task on.',
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
