// lib/platform_specific/chat/row_extent_cache.dart
//
// Measured row heights for the chat list, kept per message, so the list's
// total length (and with it the scrollbar thumb) stays put while scrolling.
//
// Why: a lazy SliverList only knows the rows it has laid out. Flutter's
// default guess for the rest is "the average height of the rows laid out
// right now, times the rows left". Every scroll changes which rows those are
// (a code block, a short "ok", a folded tool block), so the guess, the
// maxScrollExtent and the scrollbar thumb changed size and place on every
// frame. T3 Code's list (LegendList) keeps each row's measured size by key
// and uses an estimate only for rows it never saw; this is the same idea:
// every row reports its height once laid out, and the rest of the list is
// the sum of those heights, with a per-row estimate only for rows never
// built.

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Heights of laid-out rows by row key, for one list at one width.
class RowExtentCache {
  final Map<String, double> _extents = <String, double>{};
  double _width = -1;

  /// The measured height of [key], or null when it was never laid out at
  /// the current width.
  double? operator [](String? key) => key == null ? null : _extents[key];

  /// How many rows have a height (tests).
  int get length => _extents.length;

  /// Record that [key] is [height] tall at [width]. A new width drops every
  /// height measured at the old one: text wraps differently.
  void record(String key, double width, double height) {
    if ((width - _width).abs() > 0.5) {
      _extents.clear();
      _width = width;
    }
    _extents[key] = height;
  }

  /// Forget everything (a different chat opened).
  void clear() {
    _extents.clear();
    _width = -1;
  }
}

/// Rough height of a chat row that was never laid out.
///
/// Only rows the reader has not reached yet use it, and each is replaced by
/// its real height the first time it is built. The numbers: the row's chrome
/// (padding, the action bar), the text at about one line per 95 characters
/// in the 760 px column, and a folded tool block.
double estimateChatRowExtent(
  Map<String, String> row, {
  double pxPerChar = 0.3,
}) {
  final int chars = row['text']?.length ?? 0;
  final bool user = row['sender'] == 'user';
  double height = user ? 64 : 72;
  height += chars * pxPerChar;
  final String? tools = row['toolCalls'];
  if (tools != null && tools.length > 2) height += 36;
  return math.min(height, 4000);
}

/// A [SliverChildBuilderDelegate] that tells the sliver how long the rows
/// after the laid-out ones are: their measured heights from a
/// [RowExtentCache], else [extentOf]'s estimate. With it the list's length
/// only changes when a row is measured for the first time or changes size,
/// not on every scroll.
class CachedExtentChildDelegate extends SliverChildBuilderDelegate {
  CachedExtentChildDelegate(
    super.builder, {
    required int super.childCount,
    required this.extentOf,
    super.addAutomaticKeepAlives,
    super.addRepaintBoundaries,
  });

  /// Height of the child at [index]: measured, or estimated.
  final double Function(int index) extentOf;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) {
    final int count = childCount ?? 0;
    double rest = 0;
    for (int i = lastIndex + 1; i < count; i++) {
      rest += extentOf(i);
    }
    return trailingScrollOffset + rest;
  }
}

/// Reports its child's height to [cache] under [rowKey] after each layout.
/// No rebuild, no notification: the height is read by the next layout's
/// [CachedExtentChildDelegate.estimateMaxScrollOffset].
class RowExtentReporter extends SingleChildRenderObjectWidget {
  const RowExtentReporter({
    super.key,
    required this.cache,
    required this.rowKey,
    required Widget super.child,
  });

  final RowExtentCache cache;
  final String rowKey;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderRowExtentReporter(cache, rowKey);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderRowExtentReporter renderObject,
  ) {
    renderObject
      ..cache = cache
      ..rowKey = rowKey;
  }
}

/// The render object of [RowExtentReporter].
class RenderRowExtentReporter extends RenderProxyBox {
  /// Reports to [cache] under [rowKey].
  RenderRowExtentReporter(this.cache, this.rowKey);

  /// Where the height goes.
  RowExtentCache cache;

  /// The row's key in [cache].
  String rowKey;

  @override
  void performLayout() {
    super.performLayout();
    if (constraints.hasBoundedWidth) {
      cache.record(rowKey, constraints.maxWidth, size.height);
    }
  }
}
