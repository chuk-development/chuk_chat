import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/floating_app_bar.dart';

import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/skill_frontmatter_parser.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/skills/user_skills_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';
import 'package:chuk_chat/services/skills/agents_skill.dart';
import 'package:chuk_chat/services/skills/skills_source.dart';
import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

/// Lists built-in skills and lets the user author their own.
///
/// Built-ins are read-only: they are compiled into the binary and their names
/// gate protocol blocks out of the system prompt, so they are not the user's to
/// change. User skills are stored E2E-encrypted in Supabase.
class SkillsSettingsPage extends StatefulWidget {
  const SkillsSettingsPage({super.key});

  @override
  State<SkillsSettingsPage> createState() => _SkillsSettingsPageState();
}

class _SkillsSettingsPageState extends State<SkillsSettingsPage> {
  List<Skill> _userSkills = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Same deferred-hydration convention the other settings sub-pages use:
    // let the route transition finish before touching the network.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 250), _reload),
      );
    });
  }

  Future<void> _reload({bool forceRefresh = false}) async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await SkillRegistry.refreshUserSkills(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _userSkills = SkillRegistry.bySource(SkillSource.user);
        _loading = false;
      });
    } catch (error) {
      // Never swallow: a user whose skills failed to load must see why, or
      // they will think their skills vanished.
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _openEditor({Skill? skill}) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => SkillEditorPage(skill: skill)),
    );
    if (saved == true) await _reload(forceRefresh: true);
  }

  Future<void> _confirmDelete(Skill skill) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.skillDeleteTitle),
        content: Text(l.skillDeleteBody(skill.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || skill.id == null) return;

    try {
      await UserSkillsService.delete(skill.id!);
      await _reload(forceRefresh: true);
    } on UserSkillException catch (error) {
      if (!mounted) return;AppNotifications.show(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final builtins = SkillRegistry.bySource(SkillSource.builtin);

    return Scaffold(
      // The list runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        title: Text(l.skills),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const AppIcon(Icons.add),
        label: Text(l.skillNew),
      ),
      body: SettingsListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          ExpressiveInfoCard(text: l.skillsExplainer),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ExpressiveInfoCard(
              text: _error!,
              icon: Icons.error_outline,
              tone: Theme.of(context).colorScheme.errorContainer,
            ),
          ],
          ExpressiveSectionHeader(l.skillsYours),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_userSkills.isEmpty)
            _SkillsEmptyState(onCreate: () => _openEditor())
          else
            ExpressiveGroup(
              children: [
                for (final skill in _userSkills)
                  _SkillRow(
                    skill: skill,
                    onTap: () => _openEditor(skill: skill),
                    onDelete: () => _confirmDelete(skill),
                  ),
              ],
            ),
          ExpressiveSectionHeader(l.skillsBuiltin),
          ExpressiveGroup(
            children: [for (final skill in builtins) _SkillRow(skill: skill)],
          ),
        ],
      ),
    );
  }
}

/// Edits one skill's SKILL.md source.
///
/// The editor is deliberately raw markdown rather than a field-per-property
/// form: the source IS the portable artifact, it is what the spec defines, and
/// it is exactly what gets stored. A form would have to round-trip through YAML
/// anyway and would quietly drop any field it did not model.
class SkillEditorPage extends StatefulWidget {
  const SkillEditorPage({super.key, this.skill});

  /// Null to create a new skill.
  final Skill? skill;

  @override
  State<SkillEditorPage> createState() => _SkillEditorPageState();
}

class _SkillEditorPageState extends State<SkillEditorPage> {
  late final TextEditingController _controller;
  String? _error;
  String? _errorField;
  bool _saving = false;

  static const String _template = '''
---
name: my-skill
description: Does the thing. Use when the user asks for the thing, or mentions a trigger word.
---

# My skill

Write the instructions here. They are injected into the system prompt only
after the model loads this skill, so they can be as detailed as they need to
be — but keep the description above short: that one is charged to every
message.
''';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.skill == null ? _template : _sourceOf(widget.skill!),
    );
  }

  /// Reconstructs SKILL.md source from a parsed skill.
  ///
  /// The raw source is not stored separately — only the parsed result reaches
  /// the UI — so round-trip it through the same shape the parser accepts.
  String _sourceOf(Skill skill) {
    final buffer = StringBuffer()
      ..writeln('---')
      ..writeln('name: ${skill.name}')
      ..writeln('description: ${_yamlScalar(skill.description)}');
    if (skill.license != null) {
      buffer.writeln('license: ${_yamlScalar(skill.license!)}');
    }
    if (skill.compatibility != null) {
      buffer.writeln('compatibility: ${_yamlScalar(skill.compatibility!)}');
    }
    if (skill.allowedTools.isNotEmpty) {
      buffer.writeln('allowed-tools: ${skill.allowedTools.join(' ')}');
    }
    if (skill.metadata.isNotEmpty) {
      buffer.writeln('metadata:');
      for (final entry in skill.metadata.entries) {
        // Always quoted: metadata is string-to-string, and the single most
        // common key is `version: "1.0"` — emitting that bare would make YAML
        // hand back a double and the parser reject the user's own skill on
        // save, with an error that reads like they wrote it wrong.
        buffer.writeln('  ${_quote(entry.key)}: ${_quote(entry.value)}');
      }
    }
    buffer
      ..writeln('---')
      ..writeln()
      ..writeln(skill.body);
    return buffer.toString();
  }

  /// YAML scalars that a bare string would be read back as something else.
  static const Set<String> _yamlKeywords = {
    'true',
    'false',
    'yes',
    'no',
    'on',
    'off',
    'null',
    '~',
  };

  /// Quotes a scalar when YAML would otherwise mis-read it.
  ///
  /// Two classes of trap: characters that change the structure (`:` starts a
  /// nested mapping, `#` starts a comment), and values that parse as a
  /// non-string type — the parser is strict about string-to-string, so a bare
  /// `2.1` or `true` would come back as a double or a bool and be rejected.
  static String _yamlScalar(String value) {
    final needsQuotes =
        value.isEmpty ||
        value.trim() != value ||
        value.contains(':') ||
        value.contains('#') ||
        value.contains('\n') ||
        value.startsWith('-') ||
        num.tryParse(value) != null ||
        _yamlKeywords.contains(value.toLowerCase());
    return needsQuotes ? _quote(value) : value;
  }

  /// A JSON string literal is a valid YAML double-quoted scalar (YAML 1.2 is a
  /// JSON superset), and [jsonEncode] escapes newlines, tabs, quotes and
  /// control characters — all of which a hand-rolled quoter drops, silently
  /// changing what the skill means when the user reopens and saves it.
  static String _quote(String value) => jsonEncode(value);

  Future<void> _save() async {
    final l = AppLocalizations.of(context)!;
    setState(() {
      _saving = true;
      _error = null;
      _errorField = null;
    });

    try {
      await UserSkillsService.save(_controller.text, id: widget.skill?.id);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on SkillParseException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _errorField = error.field;
        _saving = false;
      });
    } on UserSkillException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _saving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '${l.skillSaveFailed}: $error';
        _saving = false;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      // The list runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(
        title: Text(widget.skill == null ? l.skillNew : l.skillEdit),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.save),
          ),
        ],
      ),
      body: SettingsListView(
        padding: const EdgeInsets.all(16),
        children: [
          ExpressiveInfoCard(text: l.skillEditorHint),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ExpressiveInfoCard(
              text: _errorField == null ? _error! : '$_errorField: $_error',
              icon: Icons.error_outline,
              tone: theme.colorScheme.errorContainer,
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: null,
            minLines: 18,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              filled: true,
              fillColor: theme.m3.surfaceContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when the user has authored no skills of their own. A quiet centred
/// panel — an icon, the explainer, and one clear way to start — instead of a
/// bare info card, so the empty state reads as an invitation, not an error.
class _SkillsEmptyState extends StatelessWidget {
  const _SkillsEmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      decoration: BoxDecoration(
        color: m3.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: m3.outlineVariant),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: m3.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: AppIcon(
              Icons.auto_awesome_outlined,
              size: 28,
              color: m3.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l.skillsYoursEmpty,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: m3.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const AppIcon(Icons.add, size: 18),
            label: Text(l.skillNew),
            style: FilledButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({required this.skill, this.onTap, this.onDelete});

  final Skill skill;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return ExpressiveRow(
      icon: skill.isBuiltin ? Icons.lock_outline : Icons.auto_awesome_outlined,
      title: skill.name,
      subtitle: skill.description,
      onTap: onTap,
      // A built-in is read-only: a state pill says so, in place of an action.
      // A user skill carries its one action, delete, and taps open to edit.
      trailing: skill.isBuiltin
          ? ExpressiveBadge(l.skillsBuiltin)
          : (onDelete == null
                ? null
                : IconButton(
                    icon: const AppIcon(Icons.delete_outline, size: 20),
                    onPressed: onDelete,
                    color: cs.onSurfaceVariant,
                    tooltip: l.delete,
                  )),
    );
  }
}

// ─── Agents: the host's own skills ───────────────────────────────────────
//
// Both products call their skills screen `SkillsSettingsPage`, but they are two
// different screens: upstream's (above) authors user skills stored in Supabase,
// Agents's (below) lists the skills that live on the coworker host and toggles
// them over the relay. Neither replaces the other, so the Agents one keeps its
// own name and every existing `SkillsSettingsPage` call site is untouched.
// Route to `AgentsSkillsSettingsPage` where FEATURE_AGENTS is on.

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
/// knows: `builtin` is a skill that documents Agents's own machinery and ships
/// with the app (the repository's `skills/builtin/`), `workspace` is any other
/// file under the coworker's `skills/` — including the ones seeded from
/// `skills/workspace/`, which belong to the coworker from the first minute.
class AgentsSkillsSettingsPage extends StatefulWidget {
  const AgentsSkillsSettingsPage({super.key, SkillsSource? source})
    : _injectedSource = source;

  final SkillsSource? _injectedSource;

  @override
  State<AgentsSkillsSettingsPage> createState() => _AgentsSkillsSettingsPageState();
}

class _AgentsSkillsSettingsPageState extends State<AgentsSkillsSettingsPage> {
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

  Future<void> _toggle(AgentsSkill skill, bool enabled) async {
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
                    'The Agents host\'s own. Each one explains a part of '
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

  Widget _row(AgentsSkill skill) => ExpressiveSwitchRow(
    key: ValueKey<String>('skill-${skill.name}'),
    title: skill.name,
    subtitle: skill.description.isEmpty ? null : skill.description,
    icon: skill.isBuiltin ? Icons.verified_outlined : Icons.folder_outlined,
    value: skill.enabled,
    onChanged: (value) => _toggle(skill, value),
  );
}
