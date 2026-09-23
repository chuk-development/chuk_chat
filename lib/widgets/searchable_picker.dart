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

import 'package:chuk_chat/platform_config.dart';
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
///
/// On a phone the list opens as a bottom sheet instead. An anchored panel
/// there covered the controls around it, clipped its first and last rows and
/// did not say what was being picked; the sheet has room for the whole list
/// and carries [title] on top.
Future<T?> showSearchablePicker<T>(
  BuildContext anchorContext, {
  required List<PickerOption<T>> options,
  String? hintText,
  String? title,
  double width = 320,
  double maxHeight = 360,
  int searchThreshold = 7,
}) {
  final ThemeData theme = Theme.of(anchorContext);
  final bool searchable = options.length >= searchThreshold;
  if (kPlatformMobile) {
    return _showPickerSheet<T>(
      anchorContext,
      options: options,
      hintText: hintText ?? 'Search',
      title: title,
      searchable: searchable,
    );
  }
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
        searchable: searchable,
      ),
    ],
  );
}

Future<T?> _showPickerSheet<T>(
  BuildContext context, {
  required List<PickerOption<T>> options,
  required String hintText,
  required String? title,
  required bool searchable,
}) {
  final ThemeData theme = Theme.of(context);
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: theme.m3.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (sheetContext) {
      final MediaQueryData media = MediaQuery.of(sheetContext);
      return Padding(
        // Lift the sheet above the keyboard while the search field is used.
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: media.size.height * 0.75),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                Flexible(
                  child: _PickerPanel<T>(
                    options: options,
                    hintText: hintText,
                    width: null,
                    maxHeight: null,
                    searchable: searchable,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
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

  /// Null fills the available width (the bottom sheet).
  final double? width;

  /// Null leaves the height to the parent (the bottom sheet caps it).
  final double? maxHeight;
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
              padding: widget.width == null
                ? const EdgeInsets.fromLTRB(16, 0, 16, 4)
                : const EdgeInsets.fromLTRB(8, 8, 8, 4),
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
                    constraints: BoxConstraints(
                      maxHeight: widget.maxHeight ?? double.infinity,
                    ),
                    child: ListView.separated(
                      padding: widget.width == null
                          ? const EdgeInsets.fromLTRB(10, 6, 10, 12)
                          : const EdgeInsets.fromLTRB(6, 6, 6, 6),
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
