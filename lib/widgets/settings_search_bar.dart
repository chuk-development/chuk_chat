// lib/widgets/settings_search_bar.dart
//
// The one search bar every settings-style page uses.
//
// It is a floating pill, not a band: the same surface the header chips, the
// sidebar bars and the composer are drawn on, with the page running on
// underneath it. A full-width opaque strip under a transparent header was
// what made the models page look broken while scrolling — the list passed
// behind the title pill, then hit a hard edge.
//
// Pinned under the header, it stays put while the list moves; a page that
// wants it inline in the list can use [SettingsSearchBar] on its own.

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Height the pinned bar reserves under the header: the field plus its air.
const double kSettingsSearchBarHeight = 60;

/// Height of the field itself. The settings rail's own search field, so the
/// two read as one control in two places.
const double _kFieldHeight = 44;

/// The search field of a settings page: a floating pill with the magnifier on
/// the left and a clear button that exists only while there is text.
class SettingsSearchBar extends StatefulWidget {
  const SettingsSearchBar({
    super.key,
    required this.controller,
    required this.hintText,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
  });

  final TextEditingController controller;
  final String hintText;
  final FocusNode? focusNode;

  /// Called on every keystroke, after the clear button has been kept in sync.
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  @override
  State<SettingsSearchBar> createState() => _SettingsSearchBarState();
}

class _SettingsSearchBarState extends State<SettingsSearchBar> {
  /// Whether the clear button belongs on screen. Tracked from the controller
  /// rather than from the host's rebuilds, so a page that debounces its own
  /// filtering does not leave the button behind.
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant SettingsSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _hasText = widget.controller.text.isNotEmpty;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final bool hasText = widget.controller.text.isNotEmpty;
    if (hasText == _hasText) return;
    setState(() => _hasText = hasText);
  }

  void _clear() {
    widget.controller.clear();
    widget.onChanged?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.m3.onSurfaceVariant;
    // A pill on the container fill, not a floating card: square-ish corners
    // and a fill a hair off the page read as a box drawn around the page,
    // which is exactly what a search field must not look like.
    return Container(
      height: _kFieldHeight,
      decoration: BoxDecoration(
        color: theme.m3.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: SizedBox(
        height: _kFieldHeight,
        child: TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          textInputAction: widget.textInputAction,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
          cursorColor: theme.colorScheme.primary,
          // The field is as tall as the pill, so the text has to be centred
          // in it: a content padding alone leaves the baseline sitting high,
          // which is what made the row look top-heavy.
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: widget.hintText,
            hintStyle: theme.textTheme.bodyMedium?.copyWith(color: muted),
            prefixIcon: AppIcon(Icons.search_rounded, size: 20, color: muted),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 44,
              minHeight: _kFieldHeight,
            ),
            suffixIcon: !_hasText
                ? null
                : InkResponse(
                    radius: 18,
                    onTap: _clear,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: AppIcon(
                        Icons.close_rounded,
                        size: 18,
                        color: muted,
                      ),
                    ),
                  ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 34,
              minHeight: 34,
            ),
            // The app theme fills every field and rounds it to kRadiusField.
            // Left on, that fill is painted OVER the pill below it, which
            // is why the bar kept looking square however round the box was.
            filled: false,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            // Every state, not just the resting one: `border` alone leaves
            // the theme's focused outline in place, and the pill then grows a
            // ring nothing else on the page has.
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
          ),
        ),
      ),
    );
  }
}

/// The same bar, sized to sit in a [FloatingAppBar]'s `bottom` slot so it
/// stays pinned under the header while the page scrolls behind it.
///
/// A page using this must add [kSettingsSearchBarHeight] to the top padding
/// of its scroll view, on top of the header inset.
class PinnedSettingsSearchBar extends StatelessWidget
    implements PreferredSizeWidget {
  const PinnedSettingsSearchBar({
    super.key,
    required this.controller,
    required this.hintText,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
  });

  final TextEditingController controller;
  final String hintText;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  @override
  Size get preferredSize => const Size.fromHeight(kSettingsSearchBarHeight);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
      child: SettingsSearchBar(
        controller: controller,
        hintText: hintText,
        focusNode: focusNode,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: textInputAction,
      ),
    );
  }
}
