/// "New agent": pick a template (or the blank coworker), then name it and
/// create it (bead chuk_chat-dsh0).
///
/// Two steps in one surface — a bottom sheet on the phone, a centred dialog
/// on a desktop window (`showAgentsSheetOrDialog`, docs/DESIGN.md §14.6):
///
///  1. **Pick.** chuk's search pill, the filter pill (All / Work / Watch /
///     Life) and the templates as expressive rows: the face the coworker
///     will get, its name and one line about it. "Blank coworker" sits on
///     top, so the old way in is one tap away.
///  2. **Name.** The name field, pre-filled from the template (the blank one
///     gets the suggested adjective-noun name), the starter automation as a
///     switch that is OFF until the user turns it on (above the fold, so it
///     is never missed), what the template works with and its instructions
///     to read. Back returns to the list.
///
/// The picker decides nothing on the wire. It pops a [CoworkerCreateRequest];
/// the shell adds the coworker, sends `agent_create` (with the template's
/// persona) and, only when the switch is on, the starter `automation_create`.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/coworker_templates.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agents_desktop/desktop_dialog.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

/// What the user asked for. [template] null is the blank coworker.
@immutable
class CoworkerCreateRequest {
  const CoworkerCreateRequest({
    required this.name,
    this.template,
    this.startAutomation = false,
  });

  /// Trimmed, never empty.
  final String name;
  final CoworkerTemplate? template;

  /// True only when the template has a starter and the user switched it on.
  final bool startAutomation;
}

/// Opens the picker. Null when the user cancelled.
Future<CoworkerCreateRequest?> showCoworkerTemplatePicker(
  BuildContext context, {
  required String suggestedName,
}) => showAgentsSheetOrDialog<CoworkerCreateRequest>(
  context: context,
  builder: (_) => CoworkerTemplatePicker(suggestedName: suggestedName),
);

class CoworkerTemplatePicker extends StatefulWidget {
  const CoworkerTemplatePicker({
    super.key,
    required this.suggestedName,
    this.templates = kCoworkerTemplates,
  });

  /// The name the blank coworker starts with.
  final String suggestedName;
  final List<CoworkerTemplate> templates;

  @override
  State<CoworkerTemplatePicker> createState() => _CoworkerTemplatePickerState();
}

/// The filter segments, in order. Null is "All".
const List<CoworkerTemplateCategory?> _segments = <CoworkerTemplateCategory?>[
  null,
  CoworkerTemplateCategory.work,
  CoworkerTemplateCategory.watch,
  CoworkerTemplateCategory.personal,
];

class _CoworkerTemplatePickerState extends State<CoworkerTemplatePicker> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final TextEditingController _name = TextEditingController();

  int _segment = 0;

  /// False on the list, true on the name step.
  bool _naming = false;
  CoworkerTemplate? _template;
  bool _startAutomation = false;
  String? _nameError;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _name.dispose();
    super.dispose();
  }

  AppLocalizations get _l =>
      AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

  /// The templates the filter pill and the search field leave. The search
  /// reads the localized name and description, so a German reader finds
  /// "Reise" and an English one "trip".
  List<CoworkerTemplate> _visible(AppLocalizations l) {
    final CoworkerTemplateCategory? category = _segments[_segment];
    final String query = _search.text.trim().toLowerCase();
    return <CoworkerTemplate>[
      for (final CoworkerTemplate template in widget.templates)
        if ((category == null || template.category == category) &&
            (query.isEmpty ||
                l.tpl(template.nameKey).toLowerCase().contains(query) ||
                l.tpl(template.descriptionKey).toLowerCase().contains(query)))
          template,
    ];
  }

  void _choose(CoworkerTemplate? template) {
    setState(() {
      _template = template;
      _naming = true;
      _startAutomation = false;
      _nameError = null;
      _name.text = template == null
          ? widget.suggestedName
          : _l.tpl(template.nameKey);
    });
  }

  void _back() => setState(() {
    _naming = false;
    _nameError = null;
  });

  void _create() {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = _l.tplNameEmpty);
      return;
    }
    Navigator.of(context).pop(
      CoworkerCreateRequest(
        name: name,
        template: _template,
        startAutomation: _startAutomation && _template?.starter != null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool desk = isAgentsDesktop(context);
    final MediaQueryData media = MediaQuery.of(context);
    // The phone sheet takes most of the screen, so the list has room; the
    // desktop dialog is already capped by `AgentsDesktopDialog`.
    final double maxHeight = desk ? double.infinity : media.size.height * 0.9;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Padding(
            padding: desk
                ? const EdgeInsets.fromLTRB(20, 20, 20, 16)
                : const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              child: _naming ? _nameStep(desk) : _pickStep(desk),
            ),
          ),
        ),
      ),
    );
  }

  // --- step 1: pick ------------------------------------------------------

  Widget _pickStep(bool desk) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = _l;
    return Column(
      key: const ValueKey<String>('tpl-step-pick'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _title(l.tplPickerTitle, desk),
        const SizedBox(height: 4),
        Text(
          l.tplPickerSubtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        SbSearchField(
          key: const ValueKey<String>('tpl-search'),
          controller: _search,
          focusNode: _searchFocus,
          hintText: l.tplSearchHint,
          onClear: () => setState(_search.clear),
        ),
        const SizedBox(height: 10),
        ConnectedGroup(
          key: const ValueKey<String>('tpl-categories'),
          margin: EdgeInsets.zero,
          labels: <String>[
            l.tplCategoryAll,
            l.tplCategoryWork,
            l.tplCategoryWatch,
            l.tplCategoryPersonal,
          ],
          selected: _segment,
          onSelected: (int index) => setState(() => _segment = index),
        ),
        const SizedBox(height: 12),
        Flexible(
          child: ListenableBuilder(
            listenable: _search,
            builder: (BuildContext context, _) {
              final List<CoworkerTemplate> rows = _visible(l);
              return ListView(
                key: const ValueKey<String>('tpl-list'),
                shrinkWrap: true,
                children: <Widget>[
                  // The blank coworker is the old way in. It stays on top
                  // while the user browses, and steps aside for a search.
                  if (_search.text.trim().isEmpty) ...<Widget>[
                    ExpressiveGroup(
                      children: <Widget>[
                        ExpressiveRow(
                          key: const ValueKey<String>('tpl-blank'),
                          leading: const CoworkerTemplateFace(template: null),
                          title: l.tplBlankName,
                          subtitle: l.tplBlankDesc,
                          onTap: () => _choose(null),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        l.tplNoMatch,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    ExpressiveGroup(
                      children: <Widget>[
                        for (final CoworkerTemplate template in rows)
                          ExpressiveRow(
                            key: ValueKey<String>('tpl-${template.id}'),
                            leading: CoworkerTemplateFace(template: template),
                            title: l.tpl(template.nameKey),
                            subtitle: l.tpl(template.descriptionKey),
                            onTap: () => _choose(template),
                          ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            ExpressiveButton(
              label: l.tplCancel,
              color: theme.colorScheme.surfaceContainerHighest,
              onColor: theme.colorScheme.onSurfaceVariant,
              dense: desk,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ],
    );
  }

  // --- step 2: name ------------------------------------------------------

  Widget _nameStep(bool desk) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme text = theme.textTheme;
    final AppLocalizations l = _l;
    final CoworkerTemplate? template = _template;
    final CoworkerStarterAutomation? starter = template?.starter;
    return Column(
      key: const ValueKey<String>('tpl-step-name'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            ExpressiveIconButton(
              key: const ValueKey<String>('tpl-back'),
              hugeIcon: HugeIcons.arrowLeft02,
              size: 40,
              tooltip: l.tplBack,
              onTap: _back,
            ),
            const SizedBox(width: 12),
            CoworkerTemplateFace(template: template, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    template == null
                        ? l.tplBlankName
                        : l.tpl(template.nameKey),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    template == null
                        ? l.tplBlankDesc
                        : l.tpl(template.descriptionKey),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _label(l.tplNameLabel),
                TextField(
                  key: const ValueKey<String>('tpl-name'),
                  controller: _name,
                  autofocus: template == null,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  cursorColor: scheme.primary,
                  style: (desk ? text.bodyLarge : text.titleMedium)?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: scheme.surfaceContainerHighest,
                    hintText: l.tplNameHint,
                    errorText: _nameError,
                    helperText: _nameError == null ? l.tplNameLater : null,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    border: _fieldBorder,
                    enabledBorder: _fieldBorder,
                    focusedBorder: _fieldBorder,
                    errorBorder: _fieldBorder,
                    focusedErrorBorder: _fieldBorder,
                  ),
                  onChanged: (_) {
                    if (_nameError != null) setState(() => _nameError = null);
                  },
                  onSubmitted: (_) => _create(),
                ),
                if (starter != null) ...<Widget>[
                  const SizedBox(height: 16),
                  _label(l.tplStarterTitle),
                  ExpressiveGroup(
                    children: <Widget>[
                      ExpressiveSwitchRow(
                        key: const ValueKey<String>('tpl-starter'),
                        title: l.tpl(starter.nameKey),
                        subtitle: l.tpl(starter.whenKey),
                        value: _startAutomation,
                        onChanged: (bool on) =>
                            setState(() => _startAutomation = on),
                      ),
                    ],
                  ),
                ],
                if (template != null && template.tools.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  _label(l.tplUses),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final CoworkerTemplateTool tool in template.tools)
                        _ToolChip(label: l.tpl('tpl.tool.${tool.name}')),
                    ],
                  ),
                ],
                if (template != null) ...<Widget>[
                  const SizedBox(height: 16),
                  _label(l.tplPersonaTitle),
                  Container(
                    key: const ValueKey<String>('tpl-persona'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      template.persona,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.tplPersonaNote,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        // A Wrap, not a Row: at 360 px and 1.3 text scale two long German
        // labels do not fit side by side, and then Create goes under Cancel.
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            ExpressiveButton(
              label: l.tplCancel,
              color: scheme.surfaceContainerHighest,
              onColor: scheme.onSurfaceVariant,
              dense: desk,
              onTap: () => Navigator.of(context).pop(),
            ),
            ExpressiveButton(
              key: const ValueKey<String>('tpl-create'),
              label: l.tplCreate,
              dense: desk,
              onTap: _create,
            ),
          ],
        ),
      ],
    );
  }

  Widget _title(String label, bool desk) {
    final TextTheme text = Theme.of(context).textTheme;
    return Text(
      label,
      style: desk
          ? text.titleLarge?.copyWith(fontWeight: FontWeight.w700)
          : text.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
    );
  }

  Widget _label(String label) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

final OutlineInputBorder _fieldBorder = OutlineInputBorder(
  borderRadius: BorderRadius.circular(kRadiusField),
  borderSide: BorderSide.none,
);

/// One "works with" hint. A quiet filled capsule: it states, it does not act.
class _ToolChip extends StatelessWidget {
  const _ToolChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The face a template's coworker gets: its silhouette in its colour, with
/// the template's icon inside. The blank coworker is a quiet round "+".
class CoworkerTemplateFace extends StatelessWidget {
  const CoworkerTemplateFace({super.key, required this.template, this.size = 42});

  final CoworkerTemplate? template;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final CoworkerTemplate? t = template;
    final Color fill = t == null
        ? scheme.surfaceContainerHighest
        : Color(t.accent);
    final Color glyph = t == null
        ? scheme.onSurfaceVariant
        : readableOnFill(fill, Colors.white);
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: fill,
          shape: t == null
              ? const CircleBorder()
              : agentAvatarShape(t.id, t.shape, size),
        ),
        child: Center(
          child: HugeIcon(
            t?.icon ?? HugeIcons.plusSign,
            size: size * 0.48,
            color: glyph,
          ),
        ),
      ),
    );
  }
}
