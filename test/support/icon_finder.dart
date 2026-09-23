import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Finds an icon whether it draws as Material or as the app's own set.
///
/// The app routes icons through [AppIcon], which swaps in a HugeIcon when the
/// map has one. `find.byIcon` only knows [Icon], so a test written against the
/// glyph would start failing the moment that glyph gets an entry — which says
/// nothing about the behaviour under test.
Finder findIcon(IconData icon) => find.byWidgetPredicate(
  // One hit per icon: an AppIcon that found no mapping still renders an Icon
  // inside itself, and counting both would make every such test say "two".
  (Widget widget) =>
      (widget is Icon && widget.icon == icon) ||
      (widget is AppIcon && widget.icon == icon && hugeIconFor(icon) != null),
  description: 'icon $icon',
);

/// The colour the icon at [finder] is drawn in, whichever widget drew it.
Color? iconColor(WidgetTester tester, Finder finder) {
  final Widget widget = tester.widget(finder);
  if (widget is Icon) return widget.color;
  if (widget is AppIcon) return widget.color;
  throw StateError('not an icon: ${widget.runtimeType}');
}

/// A widget of type [T] that contains [icon], whichever widget drew it.
///
/// Replaces `find.widgetWithIcon`, which only knows [Icon].
Finder findWidgetWithIcon<T extends Widget>(IconData icon) =>
    find.ancestor(of: findIcon(icon), matching: find.byType(T));
