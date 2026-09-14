// lib/widgets/searchable_picker.dart
//
// One list to pick from, opened at the control that asked for it.
//
// `PopupMenuButton` was doing this job and did it badly: it grows from the
// widget it wraps, so a menu opened from a full-width row started at the
// row's left edge rather than at the little arrow on its right, and with
// forty models in it the list was flung to the top of the window to fit.
// It also has no way to search — the reader had to scroll a list of every
// provider looking for a name they already knew.
//
// This is the shared replacement: anchored to whatever opened it, capped in
// height, and with a search field as soon as the list is long enough to need
// one.

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/anchored_menu.dart';
import 'package:chuk_chat/widgets/settings_search_bar.dart';

/// One row of a picker.
class PickerOption<T> {
  const PickerOption({
    required this.value,
    required this.label,
    this.subtitle,
    this.leading,
    this.selected = false,
    this.searchText,
  });

  final T value;
  final String label;

  /// The quiet second line — a price, a provider, a hint.
  final String? subtitle;

  /// An icon or logo, drawn at the head of the row.
  final Widget? leading;
  final bool selected;

  /// What the query is matched against. Null takes the label and subtitle.
  final String? searchText;

  String get _haystack =>
      (searchText ?? '$label ${subtitle ?? ''}').toLowerCase();
}

/// Opens the picker at [anchorContext]'s widget and returns the chosen value,
/// or null when it is dismissed.
///
/// The search field appears once there are [searchThreshold] options or more;
/// below that it would be one more thing to read past.
Future<T?> showSearchablePicker<T>(
  BuildContext anchorContext, {
  required List<PickerOption<T>> options,
  String? hintText,
  double width = 320,
  double maxHeight = 360,
  int searchThreshold = 7,
}) {
  final ThemeData theme = Theme.of(anchorContext);
  return showAnchoredMenu<T>(
    anchorContext,
    color: theme.m3.surfaceContainerHigh,
    borderColor: Colors.transparent,
    minWidth: width,
    outlined: true,
    items: [
      _PickerPanel<T>(
        options: options,
        hintText: hintText ?? 'Search',
        width: width,
        maxHeight: maxHeight,
        searchable: options.length >= searchThreshold,
      ),
    ],
  );
}

class _PickerPanel<T> extends StatefulWidget {
  const _PickerPanel({
    required this.options,
    required this.hintText,
    required this.width,
    required this.maxHeight,
    required this.searchable,
  });

  final List<PickerOption<T>> options;
  final String hintText;
  final double width;
  final double maxHeight;
  final bool searchable;

  @override
  State<_PickerPanel<T>> createState() => _PickerPanelState<T>();
}

class _PickerPanelState<T> extends State<_PickerPanel<T>> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<PickerOption<T>> get _matches {
    if (_query.isEmpty) return widget.options;
    return widget.options
        .where((option) => option._haystack.contains(_query))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final m3 = theme.m3;
    final List<PickerOption<T>> matches = _matches;

    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.searchable)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: SettingsSearchBar(
                controller: _search,
                hintText: widget.hintText,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
          Flexible(
            child: matches.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Text(
                      'Nothing matches "$_query".',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: m3.onSurfaceVariant,
                      ),
                    ),
                  )
                : ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: widget.maxHeight),
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                      shrinkWrap: true,
                      itemCount: matches.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 2),
                      itemBuilder: (context, index) =>
                          _row(context, matches[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, PickerOption<T> option) {
    final ThemeData theme = Theme.of(context);
    final m3 = theme.m3;
    final Color accent = theme.colorScheme.primary;
    // What is chosen is said in colour, not with a tick at the far end: the
    // eye finds the coloured row without crossing the width of the menu.
    return InkWell(
      onTap: () => Navigator.of(context).pop(option.value),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: option.selected
              ? accent.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            if (option.leading != null) ...[
              SizedBox(width: 20, height: 20, child: option.leading),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: option.selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: option.selected ? accent : null,
                    ),
                  ),
                  if (option.subtitle != null)
                    Text(
                      option.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: m3.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
