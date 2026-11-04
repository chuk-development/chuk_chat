// lib/widgets/shortcuts_dialog.dart
//
// The keyboard shortcut list (Ctrl+/, Cmd+/ on macOS). A centred dialog,
// at most 480 wide (docs/DESIGN.md §14.6): a search field, then one row per
// shortcut from [AppShortcuts], grouped by where it works. Every label
// comes from the registry, so the list cannot drift from the handlers.

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart'
    show kRadiusDialog, kRadiusMd, kRadiusXs;
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/services/shortcut_registry.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart'
    show FloatingHeaderButton;

/// Open the shortcut list over [context].
Future<void> showShortcutsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext _) => const ShortcutsDialog(),
  );
}

/// The shortcut entries whose keys or description contain [query]
/// (case-insensitive). An empty query keeps all.
List<ShortcutEntry> filterShortcuts(String query, [AppLocalizations? l10n]) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) return AppShortcuts.entries;
  return <ShortcutEntry>[
    for (final ShortcutEntry e in AppShortcuts.entries)
      if (AppShortcuts.describe(e.id, l10n).toLowerCase().contains(q) ||
          AppShortcuts.label(e.id).toLowerCase().contains(q) ||
          e.keys.toLowerCase().contains(q))
        e,
  ];
}

class ShortcutsDialog extends StatefulWidget {
  const ShortcutsDialog({super.key});

  @override
  State<ShortcutsDialog> createState() => _ShortcutsDialogState();
}

class _ShortcutsDialogState extends State<ShortcutsDialog> {
  final TextEditingController _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  String _t(
    AppLocalizations? l10n,
    String key,
    String Function(AppLocalizations) get,
  ) => l10n == null ? (stringsEn[key] ?? key) : get(l10n);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations? l10n = AppLocalizations.of(context);
    final List<ShortcutEntry> shown = filterShortcuts(_query.text, l10n);
    final List<Widget> rows = <Widget>[];
    for (final ShortcutScope scope in ShortcutScope.values) {
      final List<ShortcutEntry> inScope = <ShortcutEntry>[
        for (final ShortcutEntry e in shown)
          if (e.scope == scope) e,
      ];
      if (inScope.isEmpty) continue;
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text(
            scope == ShortcutScope.chat
                ? _t(l10n, 'shortcutsGroupChat', (l) => l.shortcutsGroupChat)
                : _t(
                    l10n,
                    'shortcutsGroupAgents',
                    (l) => l.shortcutsGroupAgents,
                  ),
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
      for (final ShortcutEntry e in inScope) {
        rows.add(_ShortcutRow(entry: e, l10n: l10n));
      }
    }

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusDialog),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 14, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _t(l10n, 'shortcutsTitle', (l) => l.shortcutsTitle),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  FloatingHeaderButton(
                    key: const ValueKey<String>('shortcuts-close'),
                    icon: Icons.close,
                    tooltip: _t(
                      l10n,
                      'shortcutsClose',
                      (l) => l.shortcutsClose,
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: TextField(
                  key: const ValueKey<String>('shortcuts-search'),
                  controller: _query,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: _t(
                      l10n,
                      'shortcutsSearchHint',
                      (l) => l.shortcutsSearchHint,
                    ),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(kRadiusMd),
                    ),
                  ),
                ),
              ),
              Flexible(
                child: rows.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          _t(
                            l10n,
                            'shortcutsNoMatch',
                            (l) => l.shortcutsNoMatch,
                          ),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    // A short list: build every row, so search and
                    // screen readers see all of them.
                    : SingleChildScrollView(
                        padding: const EdgeInsets.only(right: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: rows,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.entry, required this.l10n});

  final ShortcutEntry entry;
  final AppLocalizations? l10n;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      key: ValueKey<String>('shortcut-row-${entry.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              AppShortcuts.describe(entry.id, l10n),
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
          Wrap(
            spacing: 4,
            children: <Widget>[
              for (final String cap in AppShortcuts.keyCaps(entry.id))
                _KeyCap(cap),
            ],
          ),
        ],
      ),
    );
  }
}

/// One key, drawn as a small rounded box with a hairline.
class _KeyCap extends StatelessWidget {
  const _KeyCap(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 24, minHeight: 22),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        // Key caps take the small step of the scale (DESIGN.md §6.1).
        borderRadius: BorderRadius.circular(kRadiusXs),
        border: Border.all(color: scheme.outlineVariant, width: 0.5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          color: scheme.onSurface,
        ),
      ),
    );
  }
}
