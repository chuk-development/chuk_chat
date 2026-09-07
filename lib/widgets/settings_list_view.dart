import 'package:flutter/material.dart';

/// Scroll container for settings-style pages with a bounded set of rows.
///
/// Drop-in replacement for `ListView(padding:, children:)`. It lays every child
/// out up front via a [SingleChildScrollView] + [Column], so the scroll extent
/// is EXACT. A lazy [ListView] only *estimates* its total extent from the rows
/// it has built so far, so the estimate — and therefore the scrollbar thumb
/// size — keeps changing while you scroll. That is the "jumping scrollbar" bug.
///
/// The scrollbar track is inset by [scrollbarMargin] at both ends so it does not
/// run past the content into empty space; only the scrollbar is inset, the page
/// padding is untouched.
///
/// Use ONLY for pages with a finite, bounded list of rows (settings, detail,
/// about). Do NOT use for long, data-driven lists (chat lists, file lists) —
/// those need [ListView.builder] virtualization and must stay lazy.
class SettingsListView extends StatefulWidget {
  const SettingsListView({
    super.key,
    required this.children,
    this.padding,
    this.controller,
    this.physics,
    this.scrollbarMargin = 8,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  /// Inset of the scrollbar track from both ends, in logical pixels.
  final double scrollbarMargin;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  State<SettingsListView> createState() => _SettingsListViewState();
}

class _SettingsListViewState extends State<SettingsListView> {
  ScrollController? _internal;
  ScrollController get _controller =>
      widget.controller ?? (_internal ??= ScrollController());

  @override
  void dispose() {
    _internal?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ScrollConfiguration(
      // Suppress the ambient scrollbar the desktop ScrollBehavior would add, so
      // it does not draw on top of our inset one.
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: RawScrollbar(
        controller: _controller,
        mainAxisMargin: widget.scrollbarMargin,
        thickness: 6,
        radius: const Radius.circular(8),
        thumbColor: theme.colorScheme.onSurface.withValues(alpha: 0.35),
        child: SingleChildScrollView(
          controller: _controller,
          padding: widget.padding,
          physics: widget.physics,
          child: Column(
            crossAxisAlignment: widget.crossAxisAlignment,
            children: widget.children,
          ),
        ),
      ),
    );
  }
}
