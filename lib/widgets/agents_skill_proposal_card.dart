// lib/widgets/agents_skill_proposal_card.dart
//
// "Save as skill?" — the coworker offers to keep the procedure of a task that
// worked (docs/WIRE_CONTRACT.md, "Skill proposals"; bead chuk_chat-al2u).
//
// The card sits at the end of the transcript, like the approval and takeover
// cards. Unlike them, the run does not wait on it: the user can answer later.
// Three actions: Save skill (the draft as it is), Edit (a form, then save
// with the edits), Dismiss. The host's own reasons win over the form's
// checks and show under the fields. A decided card shrinks to one line.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/skills/skill_proposal.dart';
import 'package:chuk_chat/services/skills/skill_proposals_source.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart'
    show ExpressiveField;
import 'package:chuk_chat/widgets/markdown_message.dart';

/// Sends one answer; see [SkillProposalsSource.decide].
typedef SkillProposalDecide = Future<AgentsSkillProposalResult> Function({
  required bool accept,
  String? name,
  String? description,
  String? body,
});

class AgentsSkillProposalCard extends StatefulWidget {
  const AgentsSkillProposalCard({
    super.key,
    required this.entry,
    required this.onDecide,
    this.dense = false,
  });

  /// The proposal and where it stands.
  final SkillProposalEntry entry;

  /// Sends the answer and completes with the host's reply.
  final SkillProposalDecide onDecide;

  /// Desktop size (docs/DESIGN.md §14.8): the dense buttons.
  final bool dense;

  @override
  State<AgentsSkillProposalCard> createState() =>
      _AgentsSkillProposalCardState();
}

class _AgentsSkillProposalCardState extends State<AgentsSkillProposalCard> {
  bool _stepsOpen = false;
  bool _editing = false;
  bool _busy = false;
  bool _scrubbed = false;

  /// What went wrong with the last answer as a whole (not reachable, gone,
  /// or a host reason that names no field).
  String? _generalError;

  /// The form's own checks, after a tap on Save.
  SkillDraftFieldError? _nameCheck;
  SkillDraftFieldError? _descriptionCheck;
  SkillDraftFieldError? _bodyCheck;

  /// The host's reasons, per field, worded by the host.
  final Map<SkillDraftField, List<String>> _hostErrors =
      <SkillDraftField, List<String>>{};

  late final TextEditingController _name = TextEditingController();
  late final TextEditingController _description = TextEditingController();
  late final TextEditingController _body = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  void _openEditor() {
    final p = widget.entry.proposal;
    setState(() {
      _name.text = p.name;
      _description.text = p.description;
      _body.text = p.body;
      _editing = true;
      _generalError = null;
      _clearChecks();
    });
  }

  void _clearChecks() {
    _nameCheck = null;
    _descriptionCheck = null;
    _bodyCheck = null;
    _hostErrors.clear();
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_editing) {
      await _send(accept: true);
      return;
    }
    final String name = _name.text.trim();
    final String description = _description.text.trim();
    final String body = _body.text;
    setState(() {
      _clearChecks();
      _generalError = null;
      _nameCheck = SkillDraftRules.validateName(name);
      _descriptionCheck = SkillDraftRules.validateDescription(description);
      _bodyCheck = SkillDraftRules.validateBody(body);
    });
    if (_nameCheck != null || _descriptionCheck != null || _bodyCheck != null) {
      return;
    }
    // Only what changed rides along: an absent field keeps the draft's value.
    final p = widget.entry.proposal;
    await _send(
      accept: true,
      name: name == p.name ? null : name,
      description: description == p.description ? null : description,
      body: body == p.body ? null : body,
    );
  }

  Future<void> _send({
    required bool accept,
    String? name,
    String? description,
    String? body,
  }) async {
    setState(() {
      _busy = true;
      _generalError = null;
    });
    final AgentsSkillProposalResult result = await widget.onDecide(
      accept: accept,
      name: name,
      description: description,
      body: body,
    );
    if (!mounted) return;
    final AppLocalizations? l = AppLocalizations.of(context);
    setState(() {
      _busy = false;
      _scrubbed = result.scrubbed;
      if (result.isDecided) {
        _editing = false;
        return;
      }
      switch (result.status) {
        case AgentsSkillProposalResult.statusInvalid:
          // The host's word is the truth. A plain Save the host refused (a
          // name already taken) opens the form, so the user can fix it.
          if (!_editing) _openEditorFields();
          _hostErrors.clear();
          final List<String> general = <String>[];
          for (final String error in result.errors) {
            final SkillDraftField? field = skillDraftFieldForHostError(error);
            if (field == null) {
              general.add(error);
            } else {
              (_hostErrors[field] ??= <String>[]).add(error);
            }
          }
          _generalError = general.isEmpty ? null : general.join('\n');
        case AgentsSkillProposalResult.statusNotFound:
          _generalError =
              l?.skillProposalErrNotFound ??
              'Your computer no longer has this offer.';
        default:
          final bool offline =
              result.errors.isNotEmpty &&
              result.errors.first == 'not_connected';
          _generalError = offline
              ? (l?.skillProposalErrNotConnected ??
                    'Not connected to your computer. Try again when it is '
                        'back.')
              : (l?.skillProposalErrNoAnswer ??
                    'Your computer did not answer. Try again.');
      }
    });
  }

  /// Fills the form from the draft without a second setState.
  void _openEditorFields() {
    final p = widget.entry.proposal;
    _name.text = p.name;
    _description.text = p.description;
    _body.text = p.body;
    _editing = true;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l = AppLocalizations.of(context);
    final SkillProposalEntry entry = widget.entry;

    final Widget content = switch (entry.state) {
      SkillProposalState.saved => _decided(
        theme,
        key: const ValueKey<String>('agents-skill-proposal-saved'),
        icon: HugeIcons.checkmarkCircle02,
        iconColor: theme.accentForegroundOn(scheme.surfaceContainerHigh),
        text: _savedLine(
          theme,
          l?.skillProposalSaved ?? 'Saved as skill {name}',
          entry.savedName ?? entry.proposal.name,
        ),
        note: _scrubbed
            ? (l?.skillProposalScrubbed ??
                  'Secrets and personal data were removed from the skill.')
            : null,
      ),
      SkillProposalState.dismissed => _decided(
        theme,
        key: const ValueKey<String>('agents-skill-proposal-dismissed'),
        icon: HugeIcons.cancel01,
        iconColor: scheme.onSurfaceVariant,
        text: Text(
          l?.skillProposalNotSaved ?? 'Not saved',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      SkillProposalState.pending => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _header(theme, l),
          const SizedBox(height: 10),
          if (_editing) ..._form(theme, l) else ..._summary(theme, l),
          if (_generalError != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _generalError!,
              key: const ValueKey<String>('agents-skill-proposal-error'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: 12),
          _actions(scheme, l),
        ],
      ),
    };

    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: ValueKey<String>('agents-skill-proposal-${entry.proposalId}'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: entry.isPending
            ? const EdgeInsets.fromLTRB(16, 14, 16, 14)
            : const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: content,
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, AppLocalizations? l) {
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: HugeIcon(
            HugeIcons.sparkles,
            size: 20,
            color: scheme.onSecondaryContainer,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            l?.skillProposalTitle ?? 'Save as skill?',
            key: const ValueKey<String>('agents-skill-proposal-title'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  /// The draft as the agent wrote it: name, description, the steps behind
  /// "Show steps".
  List<Widget> _summary(ThemeData theme, AppLocalizations? l) {
    final ColorScheme scheme = theme.colorScheme;
    final p = widget.entry.proposal;
    return <Widget>[
      Text(
        p.name,
        key: const ValueKey<String>('agents-skill-proposal-name'),
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
        ),
      ),
      if (p.description.isNotEmpty) ...<Widget>[
        const SizedBox(height: 4),
        Text(
          p.description,
          key: const ValueKey<String>('agents-skill-proposal-description'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
      if (p.body.trim().isNotEmpty) ...<Widget>[
        const SizedBox(height: 6),
        MorphTap(
          key: const ValueKey<String>('agents-skill-proposal-steps-toggle'),
          onTap: () => setState(() => _stepsOpen = !_stepsOpen),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _stepsOpen
                    ? (l?.skillProposalHideSteps ?? 'Hide steps')
                    : (l?.skillProposalShowSteps ?? 'Show steps'),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.accentForegroundOn(scheme.surfaceContainerHigh),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              HugeIcon(
                _stepsOpen ? HugeIcons.arrowUp01 : HugeIcons.arrowDown01,
                size: 16,
                color: theme.accentForegroundOn(scheme.surfaceContainerHigh),
              ),
            ],
          ),
        ),
        if (_stepsOpen)
          Container(
            key: const ValueKey<String>('agents-skill-proposal-steps'),
            width: double.infinity,
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
            ),
            child: MarkdownMessage(
              text: p.body,
              textColor: scheme.onSurface,
              backgroundColor: scheme.surfaceContainerLow,
              wrapWithSelectionArea: false,
            ),
          ),
      ],
    ];
  }

  List<Widget> _form(ThemeData theme, AppLocalizations? l) {
    final List<String> nameErrors = <String>[
      if (_nameCheck != null) _checkText(l, _nameCheck!),
      ...?_hostErrors[SkillDraftField.name],
    ];
    final List<String> descriptionErrors = <String>[
      if (_descriptionCheck != null) _checkText(l, _descriptionCheck!),
      ...?_hostErrors[SkillDraftField.description],
    ];
    final List<String> bodyErrors = <String>[
      if (_bodyCheck != null) _checkText(l, _bodyCheck!),
      ...?_hostErrors[SkillDraftField.body],
    ];
    return <Widget>[
      _field(
        theme,
        key: 'name',
        controller: _name,
        label: l?.skillProposalNameLabel ?? 'Name',
        help:
            l?.skillProposalNameHelp ??
            'Lower-case letters and digits, joined by hyphens.',
        errors: nameErrors,
        formatters: <TextInputFormatter>[
          LengthLimitingTextInputFormatter(SkillDraftRules.maxNameChars),
        ],
      ),
      _field(
        theme,
        key: 'description',
        controller: _description,
        label: l?.skillProposalDescriptionLabel ?? 'Description',
        errors: descriptionErrors,
        maxLines: 4,
        // One line: Enter does not start a second one.
        formatters: <TextInputFormatter>[
          FilteringTextInputFormatter.deny(RegExp(r'[\r\n]')),
        ],
        counter: true,
      ),
      _field(
        theme,
        key: 'body',
        controller: _body,
        label: l?.skillProposalBodyLabel ?? 'Steps',
        errors: bodyErrors,
        minLines: 4,
        maxLines: 14,
        multiline: true,
      ),
    ];
  }

  Widget _field(
    ThemeData theme, {
    required String key,
    required TextEditingController controller,
    required String label,
    required List<String> errors,
    String? help,
    int minLines = 1,
    int maxLines = 1,
    bool multiline = false,
    bool counter = false,
    List<TextInputFormatter>? formatters,
  }) {
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ExpressiveField(
            child: TextField(
              key: ValueKey<String>('agents-skill-proposal-field-$key'),
              controller: controller,
              enabled: !_busy,
              minLines: minLines,
              maxLines: maxLines,
              keyboardType: multiline
                  ? TextInputType.multiline
                  : TextInputType.text,
              autocorrect: key != 'name',
              inputFormatters: formatters,
              style: key == 'name'
                  ? theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    )
                  : null,
              decoration: InputDecoration(
                border: InputBorder.none,
                labelText: label,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (errors.isNotEmpty || help != null || counter)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      errors.isNotEmpty ? errors.join('\n') : (help ?? ''),
                      key: ValueKey<String>(
                        'agents-skill-proposal-$key-'
                        '${errors.isNotEmpty ? 'error' : 'help'}',
                      ),
                      style: small?.copyWith(
                        color: errors.isNotEmpty
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (counter)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '${controller.text.trim().length}/'
                        '${SkillDraftRules.maxDescriptionChars}',
                        key: ValueKey<String>(
                          'agents-skill-proposal-$key-count',
                        ),
                        style: small?.copyWith(
                          color:
                              controller.text.trim().length >
                                  SkillDraftRules.maxDescriptionChars
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _actions(ColorScheme scheme, AppLocalizations? l) {
    if (_busy) {
      return const Padding(
        key: ValueKey<String>('agents-skill-proposal-busy'),
        padding: EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final String save = l?.skillProposalSave ?? 'Save skill';
    final List<Widget> buttons = _editing
        ? <Widget>[
            _button('save', save, filled: true, onTap: _save),
            _button(
              'cancel',
              l?.skillProposalCancel ?? 'Cancel',
              onTap: () => setState(() {
                _editing = false;
                _generalError = null;
                _clearChecks();
              }),
            ),
          ]
        : <Widget>[
            // One filled target: the answer the agent asked for.
            _button('save', save, filled: true, onTap: _save),
            _button('edit', l?.skillProposalEdit ?? 'Edit', onTap: _openEditor),
            _button(
              'dismiss',
              l?.skillProposalDismiss ?? 'Dismiss',
              onTap: () => _send(accept: false),
            ),
          ];
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _button(
    String id,
    String label, {
    required VoidCallback onTap,
    bool filled = false,
  }) =>
      // A button never grows wider than the card: on a narrow phone at a
      // large text size it scales down instead of overflowing.
      FittedBox(
        fit: BoxFit.scaleDown,
        child: ExpressiveButton(
          key: ValueKey<String>('agents-skill-proposal-$id'),
          label: label,
          tonal: !filled,
          dense: widget.dense,
          onTap: onTap,
        ),
      );

  Widget _decided(
    ThemeData theme, {
    required Key key,
    required HugeIconData icon,
    required Color iconColor,
    required Widget text,
    String? note,
  }) {
    return Row(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: HugeIcon(icon, size: 18, color: iconColor),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              text,
              if (note != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  note,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// "Saved as skill `name`": the template's `{name}` drawn in code style.
  Widget _savedLine(ThemeData theme, String template, String name) {
    final TextStyle? base = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    final int at = template.indexOf('{name}');
    final List<InlineSpan> spans = at < 0
        ? <InlineSpan>[TextSpan(text: '$template $name')]
        : <InlineSpan>[
            if (at > 0) TextSpan(text: template.substring(0, at)),
            TextSpan(
              text: name,
              style: TextStyle(
                fontFamily: 'monospace',
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (at + 6 < template.length)
              TextSpan(text: template.substring(at + 6)),
          ];
    return Text.rich(
      TextSpan(style: base, children: spans),
      key: const ValueKey<String>('agents-skill-proposal-saved-text'),
    );
  }

  static String _checkText(AppLocalizations? l, SkillDraftFieldError error) =>
      switch (error) {
        SkillDraftFieldError.nameEmpty =>
          l?.skillProposalErrNameEmpty ?? 'Give the skill a name.',
        SkillDraftFieldError.nameTooLong =>
          l?.skillProposalErrNameTooLong ??
              'The name has more than 64 characters.',
        SkillDraftFieldError.nameInvalid =>
          l?.skillProposalErrNameInvalid ??
              'Use lower-case letters and digits joined by single hyphens, '
                  'for example weekly-report.',
        SkillDraftFieldError.descriptionEmpty =>
          l?.skillProposalErrDescriptionEmpty ??
              'Write one line that says what the skill does.',
        SkillDraftFieldError.descriptionTooLong =>
          l?.skillProposalErrDescriptionTooLong ??
              'The description has more than 300 characters.',
        SkillDraftFieldError.descriptionMultiline =>
          l?.skillProposalErrDescriptionMultiline ??
              'The description must be one line.',
        SkillDraftFieldError.bodyEmpty =>
          l?.skillProposalErrBodyEmpty ?? 'The steps are empty.',
        SkillDraftFieldError.bodyTooLong =>
          l?.skillProposalErrBodyTooLong ??
              'The steps are too long: at most 500 lines and 40000 '
                  'characters.',
      };
}
