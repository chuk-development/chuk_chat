import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/skill_frontmatter_parser.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/skills/user_skills_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

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
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final builtins = SkillRegistry.bySource(SkillSource.builtin);

    return Scaffold(
      appBar: AppBar(title: Text(l.skills), centerTitle: false),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: Text(l.skillNew),
      ),
      body: ListView(
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
            ExpressiveInfoCard(text: l.skillsYoursEmpty)
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
      appBar: AppBar(
        title: Text(widget.skill == null ? l.skillNew : l.skillEdit),
        centerTitle: false,
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
      body: ListView(
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
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: onDelete,
                    color: cs.onSurfaceVariant,
                    tooltip: l.delete,
                  )),
    );
  }
}
