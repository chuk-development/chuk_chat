/// The mechanics behind `every_screen_layout_test.dart`.
///
/// Three questions are asked of every screen, at every window size and every
/// text scale:
///
///  1. did anything throw, and did anything overflow?
///  2. does anything paint past the left or right edge of the window?
///  3. is every control at least [MobileLayout.minTouchTarget] in both
///     directions?
///
/// The walkers are deliberately structural: they name nothing, so a control
/// added tomorrow is measured tomorrow without anyone listing it here.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/ui/expressive/motion.dart';

import '../support/test_app.dart';

/// One window the app has to fit into.
class LayoutSize {
  const LayoutSize(this.name, this.size);

  final String name;
  final Size size;

  @override
  String toString() =>
      '$name (${size.width.toInt()}x${size.height.toInt()})';
}

const List<LayoutSize> kLayoutSizes = <LayoutSize>[
  LayoutSize('phone-360', Size(360, 800)),
  LayoutSize('phone-412', Size(412, 892)),
  LayoutSize('tablet-800', Size(800, 1200)),
  LayoutSize('desktop-1400', Size(1400, 900)),
];

const List<double> kTextScales = <double>[1.0, 1.3];

/// Pumps [child] into a window of [size] with text scaled by [textScale].
///
/// The scaler is installed BELOW `MaterialApp`, through its builder: the app
/// rebuilds `MediaQuery` from the view, so a scaler placed above it is thrown
/// away. The window itself comes from the view, which is why the physical size
/// is set rather than a `MediaQuery` faked around the app.
Future<void> pumpAt(
  WidgetTester tester,
  Widget child, {
  required Size size,
  required double textScale,
  Duration settle = const Duration(seconds: 2),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewInsets = FakeViewPadding.zero;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (BuildContext context, Widget? inner) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: inner ?? const SizedBox.shrink(),
      ),
      home: child,
    ),
  );
  // The localisation delegates load asynchronously; the first frame is empty.
  await tester.pump();
  await tester.pump(settle);
  try {
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  } on FlutterError {
    // A screen with an endless animation (a spinner while it waits for the
    // host) never settles. Its frames are already pumped; carry on.
  }
}

/// Unmounts the screen and drains what it started, INSIDE the test body.
///
/// `addTearDown` is too late: the binding checks for pending timers at the end
/// of the body, before teardown callbacks run, and several screens schedule a
/// delayed refresh on mount.
Future<void> unpump(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  try {
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  } on FlutterError {
    // ignore: nothing left on screen to settle.
  }
}

// ---------------------------------------------------------------------------
// 1. nothing threw, nothing overflowed
// ---------------------------------------------------------------------------

/// Collects every framework error raised while [body] runs.
///
/// `tester.takeException()` hands back only the FIRST error; a screen that
/// overflows in four places would report one and hide three. This takes the
/// error sink itself, so the report lists all of them.
Future<List<FlutterErrorDetails>> collectErrors(
  Future<void> Function() body,
) async {
  final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
  final void Function(FlutterErrorDetails)? previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

String describeErrors(List<FlutterErrorDetails> errors) => errors
    .map((FlutterErrorDetails d) => d.exception.toString().split('\n').first)
    .join('\n  ');

bool isOverflow(FlutterErrorDetails d) =>
    d.exception.toString().contains('overflowed by');

// ---------------------------------------------------------------------------
// 2. nothing paints past the left or right edge
// ---------------------------------------------------------------------------

/// A box whose painted rect leaves the window sideways.
class Bleed {
  const Bleed(this.what, this.rect);

  final String what;
  final Rect rect;

  @override
  String toString() =>
      '$what at ${rect.left.toStringAsFixed(1)}..'
      '${rect.right.toStringAsFixed(1)}';
}

const double _kEdgeTolerance = 0.5;

/// True when [element] scrolls sideways, so its content is MEANT to be wider
/// than the window.
bool _scrollsHorizontally(Element element) {
  final Widget w = element.widget;
  if (w is Scrollable) {
    return axisDirectionToAxis(w.axisDirection) == Axis.horizontal;
  }
  return false;
}

/// True when nothing under [element] paints at all.
bool _paintsNothing(Element element) {
  final Widget w = element.widget;
  if (w is Offstage) return w.offstage;
  if (w is Visibility) return !w.visible;
  // The framework's own text-selection handles. They live in the overlay,
  // they are dragged rather than laid out, and they are the framework's
  // business, not this app's layout.
  return w.runtimeType.toString().startsWith('_SelectionHandleOverlay');
}

/// True for a node whose OWN box is measured in its parent's coordinates
/// while what it paints is scaled or moved somewhere else — the floating
/// label of a text field is the common one. Its children are still measured,
/// through the real transform, so nothing is lost by skipping the node.
bool _paintsElsewhere(Element element) {
  final Widget w = element.widget;
  return w is Transform ||
      w is MatrixTransition ||
      w is ScaleTransition ||
      w is RotationTransition ||
      w is SlideTransition ||
      w is FractionalTranslation ||
      w is CompositedTransformFollower;
}

/// True for a box that is told to let its child be bigger than itself. What
/// happens under it is the author's decision, not a layout fault.
bool _mayOverhang(Element element) {
  final Widget w = element.widget;
  return w is OverflowBox ||
      w is SizedOverflowBox ||
      w is FittedBox ||
      w is UnconstrainedBox;
}

/// True when [element] cuts its children off at its own edge, so nothing
/// under it can paint past the window if the element itself does not.
///
/// A scroll viewport is deliberately NOT in this list. It does clip, but a
/// row that is wider than a vertical list is content the user cannot reach —
/// exactly the fault this walk is for. Sideways scrolling is handled
/// separately, by [_scrollsHorizontally].
bool _clipsChildren(Element element) {
  final Widget w = element.widget;
  if (w is ClipRect || w is ClipRRect || w is ClipOval || w is ClipPath) {
    return true;
  }
  if (w is Stack) return w.clipBehavior != Clip.none;
  if (w is Material) return w.clipBehavior != Clip.none;
  if (w is Card) return w.clipBehavior != null && w.clipBehavior != Clip.none;
  if (w is Container) return w.clipBehavior != Clip.none;
  return false;
}

/// Walks the tree under the root and returns every box that paints past the
/// left or right edge of [screen].
///
/// A box inside a horizontal [Scrollable] is skipped: sideways scrolling is
/// how that content is supposed to reach past the edge. A box inside a
/// vertical one is NOT skipped — a row that is wider than a vertical list is
/// cut off, and that is the bug this looks for.
List<Bleed> findHorizontalBleed(WidgetTester tester, Size screen) {
  final List<Bleed> out = <Bleed>[];
  final Rect window = Offset.zero & screen;

  void walk(Element element, bool exempt, List<String> path) {
    if (_paintsNothing(element)) return;
    final List<String> here = <String>[
      ...path.length >= 6 ? path.sublist(path.length - 6) : path,
      element.widget.runtimeType.toString(),
    ];

    if (!exempt &&
        element is RenderObjectElement &&
        !_paintsElsewhere(element)) {
      final RenderObject render = element.renderObject;
      if (render is RenderBox &&
          render.attached &&
          render.hasSize &&
          !render.debugNeedsLayout &&
          !render.size.isEmpty) {
        // The whole rect through the whole transform: a box inside a scaled
        // parent (the floating label of a text field) is only as wide as it
        // is PAINTED, not as wide as it was laid out.
        final Rect rect = MatrixUtils.transformRect(
          render.getTransformTo(null),
          Offset.zero & render.size,
        );
        if (rect.left < window.left - _kEdgeTolerance ||
            rect.right > window.right + _kEdgeTolerance) {
          out.add(Bleed(here.join(' > '), rect));
        }
      }
    }
    final bool nowExempt = exempt ||
        _scrollsHorizontally(element) ||
        _mayOverhang(element) ||
        _clipsChildren(element);
    element.visitChildren((Element child) => walk(child, nowExempt, here));
  }

  walk(tester.binding.rootElement!, false, const <String>[]);
  // A parent that bleeds drags every child with it; one line per screen is
  // enough to find the culprit, and the outermost one is the culprit.
  final List<Bleed> trimmed = <Bleed>[];
  for (final Bleed b in out) {
    if (trimmed.any((Bleed seen) => b.what.startsWith(seen.what))) continue;
    trimmed.add(b);
  }
  return trimmed;
}

// ---------------------------------------------------------------------------
// 3. every control is 48 dp
// ---------------------------------------------------------------------------

/// True for a widget that takes a tap and is therefore a touch target.
///
/// Copied from `test/platform_specific/mobile/touch_target_walk_test.dart`,
/// which is the precedent for this walk.
bool isTarget(Widget w) {
  if (w is IconButton) return w.onPressed != null;
  if (w is MorphTap) return w.onTap != null || w.onLongPress != null;
  if (w is TextButton || w is ElevatedButton || w is OutlinedButton) {
    return true;
  }
  if (w is FilledButton || w is SegmentedButton) return true;
  // Every chip type builds one of these, and it is the RawChip — not the ink
  // well inside it — that owns the 48 dp tap pad.
  if (w is RawChip) return w.isEnabled;
  if (w is InkResponse) return w.onTap != null || w.onLongPress != null;
  if (w is GestureDetector) return w.onTap != null || w.onLongPress != null;
  return false;
}

/// True for the widgets that build their own ink well INSIDE a 48 dp tap
/// pad. Measuring that inner ink well reports the visual size (40 dp for a
/// Material button), not the size of the area a finger actually hits, so the
/// walk measures the outer widget and skips what it wraps.
bool _ownsItsPadding(Widget w) =>
    w is RawChip ||
    w is InkResponse ||
    w is IconButton ||
    w is ButtonStyleButton ||
    w is SegmentedButton ||
    w is Switch ||
    w is Checkbox ||
    w is Radio ||
    w is PopupMenuButton ||
    w is DropdownButton ||
    w is MorphTap ||
    w is EditableText ||
    w is Slider;

/// A control that is too small to hit.
class SmallTarget {
  const SmallTarget(this.what, this.size);

  final String what;
  final Size size;

  @override
  String toString() => '$what is '
      '${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}';
}

List<SmallTarget> findSmallTargets(WidgetTester tester) {
  final List<SmallTarget> out = <SmallTarget>[];

  void walk(Element element, bool padded, List<String> path) {
    if (_paintsNothing(element)) return;
    final Widget w = element.widget;
    final List<String> here = <String>[
      ...path.length >= 4 ? path.sublist(path.length - 4) : path,
      w.runtimeType.toString(),
    ];
    if (!padded && isTarget(w)) {
      final RenderObject? render = element.renderObject;
      if (render is RenderBox && render.hasSize && !render.size.isEmpty) {
        final Size size = render.size;
        if (size.width < MobileLayout.minTouchTarget ||
            size.height < MobileLayout.minTouchTarget) {
          out.add(SmallTarget(here.join(' > '), size));
        }
      }
    }
    final bool nowPadded = padded || _ownsItsPadding(w);
    element.visitChildren((Element child) => walk(child, nowPadded, here));
  }

  walk(tester.binding.rootElement!, false, const <String>[]);
  // The same row repeated down a list says the same thing ten times.
  final List<SmallTarget> unique = <SmallTarget>[];
  for (final SmallTarget t in out) {
    if (unique.any((SmallTarget seen) =>
        seen.what == t.what && seen.size == t.size)) {
      continue;
    }
    unique.add(t);
  }
  return unique;
}

// ---------------------------------------------------------------------------
// 4. no text too small to read
// ---------------------------------------------------------------------------

/// Text below this many logical pixels is decoration, not writing. Material
/// puts its smallest label style (`labelSmall`) at 11.
const double kMinFontSize = 10.0;

class TinyText {
  const TinyText(this.text, this.fontSize);

  final String text;
  final double fontSize;

  @override
  String toString() => '"$text" at ${fontSize.toStringAsFixed(1)} px';
}

/// Every run of text painted smaller than [kMinFontSize].
///
/// Icons are drawn as text too, and an icon is not writing, so a span whose
/// style has no font family of its own AND whose text is a single private-use
/// glyph is skipped.
List<TinyText> findTinyText(WidgetTester tester) {
  final List<TinyText> out = <TinyText>[];

  void span(InlineSpan node, double inherited) {
    double size = inherited;
    if (node is TextSpan) {
      size = node.style?.fontSize ?? inherited;
      final String? text = node.text;
      if (text != null && text.trim().isNotEmpty && size < kMinFontSize) {
        final bool isGlyph = text.runes.length == 1 &&
            text.runes.first >= 0xE000 &&
            text.runes.first <= 0xF8FF;
        if (!isGlyph) out.add(TinyText(text, size));
      }
      for (final InlineSpan child in node.children ?? const <InlineSpan>[]) {
        span(child, size);
      }
    }
  }

  void walk(Element element) {
    if (_paintsNothing(element)) return;
    final RenderObject? render = element is RenderObjectElement
        ? element.renderObject
        : null;
    if (render is RenderParagraph) {
      span(render.text, render.text.style?.fontSize ?? kMinFontSize);
    }
    element.visitChildren(walk);
  }

  walk(tester.binding.rootElement!);
  final List<TinyText> unique = <TinyText>[];
  for (final TinyText t in out) {
    if (unique.any((TinyText s) => s.text == t.text && s.fontSize == t.fontSize)) {
      continue;
    }
    unique.add(t);
  }
  return unique;
}
