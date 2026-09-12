import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Finds an icon whichever widget draws it.
///
/// The app renders its icons through [AppIcon], which falls back to Material's
/// [Icon] for a glyph the HugeIcons set does not carry. `find.byIcon` only
/// knows the second of those, so a test written against it would pass or fail
/// depending on whether that one glyph happens to have an SVG.
/// Matches [AppIcon] only. Every icon the app draws goes through it, and it
/// renders a Material [Icon] for an unmapped glyph — so matching both would
/// count the fallback twice.
Finder findIcon(IconData icon) => find.byWidgetPredicate(
      (widget) => widget is AppIcon && widget.icon == icon,
      description: 'icon $icon',
    );

/// [find.widgetWithIcon] for the same reason.
Finder findWidgetWithIcon(Type type, IconData icon) => find.ancestor(
      of: findIcon(icon),
      matching: find.byType(type),
    );
