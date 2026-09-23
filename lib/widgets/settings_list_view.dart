import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/ui/expressive/staggered.dart';

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
/// Every row enters on the app's [StaggeredItem] cascade, so a settings page
/// arrives the way the rest of the app does. Reduced motion drops the cascade.
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
    this.headerInset = true,
    this.extraHeaderInset = 0,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final ScrollPhysics? physics;

  /// Inset of the scrollbar track from both ends, in logical pixels.
  final double scrollbarMargin;

  /// Leave room at the top for the page's floating header.
  ///
  /// True for a page, false inside a dialog or a sheet, which has no header
  /// of its own and would open on a band of empty space.
  final bool headerInset;

  /// Height of whatever the floating header carries under itself — a pinned
  /// search field, say. Counted into the room left at the top.
  final double extraHeaderInset;
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

  EdgeInsetsGeometry _withHeaderInset(
    BuildContext context,
    EdgeInsetsGeometry? padding,
  ) => widget.headerInset
      ? (padding ?? EdgeInsets.zero).add(
          floatingHeaderInset(context, extra: widget.extraHeaderInset),
        )
      : (padding ?? EdgeInsets.zero);

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
          // The header floats over the page, so the list runs underneath it
          // and the inset it needs is *inside* the scroll view: padding put
          // outside would stop the content at the header instead of letting
          // it pass behind. A Scaffold that extends its body behind the app
          // bar reports the bar's height here; one that does not reports
          // zero, so this is a no-op on a page with a solid bar.
          padding: _withHeaderInset(context, widget.padding),
          physics: widget.physics,
          child: Column(
            crossAxisAlignment: widget.crossAxisAlignment,
            // Every row cascades in, one after the other. The rows are
            // bounded and all built up front, so the whole page can carry the
            // entrance the rest of the app has.
            children: <Widget>[
              for (var i = 0; i < widget.children.length; i++)
                StaggeredItem(index: i, child: widget.children[i]),
            ],
          ),
        ),
      ),
    );
  }
}
