// App-side half of the agent driver (tool/agent_driver, docs/AGENT_DRIVER.md).
//
// Only `test_driver/main_agent.dart` imports this file. The release app does
// not contain it.
//
// It adds to the Flutter Driver extension:
//
// * The finder type `Agent` (`AgentFinderExtension`). One finder for all the
//   ways an agent names a widget: text, part of a text, tooltip, semantics
//   identifier, semantics label, value key, widget type, icon code point.
//   `index` picks one match when there are more. `hittable` keeps only
//   matches that receive a tap at their centre.
// * The service extensions `ext.chuk.agent.screenshot`,
//   `ext.chuk.agent.state` and `ext.chuk.agent.tapAt`.

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_driver/flutter_driver.dart' show SerializableFinder;
import 'package:flutter_test/flutter_test.dart'
    show ChainedFinder, CommonFinders, Finder, Plurality, TestPointer, find;

import 'package:chuk_chat/main.dart' show appCaptureBoundaryKey;
import 'package:chuk_chat/widgets/icons/icon_map.dart' show AppIcon;

/// The ways to name a widget. The MCP tool schema uses the same names.
const List<String> agentFinderKinds = <String>[
  'text',
  'text_contains',
  'tooltip',
  'semantics_id',
  'semantics_label',
  'key',
  'type',
  'icon',
];

/// A serializable finder for [AgentFinderExtension].
class AgentFinder extends SerializableFinder {
  const AgentFinder({
    required this.by,
    required this.value,
    this.index = 0,
    this.hittable = false,
  });

  final String by;
  final String value;
  final int index;
  final bool hittable;

  @override
  String get finderType => 'Agent';

  @override
  Map<String, String> serialize() => super.serialize()
    ..addAll(<String, String>{
      'by': by,
      'value': value,
      'index': '$index',
      'hittable': '$hittable',
    });
}

/// Builds the [Finder] for an [AgentFinder]. Kept apart from the driver
/// plumbing, so widget tests can use it directly.
Finder agentFinder(AgentFinder f, {CommonFinders finders = find}) {
  final String v = f.value;
  final Finder base = switch (f.by) {
    'text' => finders.text(v, findRichText: true),
    'text_contains' => finders.textContaining(v, findRichText: true),
    'tooltip' => finders.byTooltip(v),
    'semantics_id' => finders.byWidgetPredicate(
      (Widget w) => w is Semantics && w.properties.identifier == v,
      description: 'Semantics(identifier: "$v")',
    ),
    'semantics_label' => finders.byWidgetPredicate(
      (Widget w) =>
          (w is Semantics && w.properties.label == v) ||
          (w is Icon && w.semanticLabel == v) ||
          (w is AppIcon && w.semanticLabel == v),
      description: 'semantics label "$v"',
    ),
    'key' => finders.byKey(ValueKey<String>(v)),
    'type' => finders.byWidgetPredicate(
      (Widget w) => w.runtimeType.toString() == v,
      description: 'widget type $v',
    ),
    'icon' => _iconFinder(finders, v),
    _ => throw ArgumentError(
      'Unknown finder kind "${f.by}". Use one of: ${agentFinderKinds.join(', ')}',
    ),
  };
  final Finder filtered = f.hittable ? base.hitTestable() : base;
  return _NthFinder(filtered, f.index);
}

/// Keeps match number [index] of [parent]. Unlike `Finder.first` and
/// `Finder.at`, it finds nothing (and does not throw) when there are fewer
/// matches, so the driver can keep waiting for the widget.
class _NthFinder extends ChainedFinder {
  _NthFinder(super.parent, this.index);

  final int index;

  @override
  String get description =>
      '${parent.describeMatch(Plurality.many)} (match #$index)';

  @override
  Iterable<Element> filter(Iterable<Element> parentCandidates) =>
      parentCandidates.skip(index).take(1);
}

Finder _iconFinder(CommonFinders finders, String value) {
  final int? codePoint = parseCodePoint(value);
  if (codePoint == null) {
    throw ArgumentError(
      'icon needs a code point, e.g. "0xe5d2" (got "$value")',
    );
  }
  return finders.byWidgetPredicate(
    (Widget w) =>
        (w is AppIcon && w.icon?.codePoint == codePoint) ||
        (w is Icon && w.icon?.codePoint == codePoint),
    description: 'icon 0x${codePoint.toRadixString(16)}',
  );
}

/// Parses "0xe5d2", "e5d2" or "58834".
int? parseCodePoint(String value) {
  final String s = value.trim().toLowerCase();
  if (s.startsWith('0x')) return int.tryParse(s.substring(2), radix: 16);
  return int.tryParse(s) ?? int.tryParse(s, radix: 16);
}

/// The Flutter Driver side of [AgentFinder].
class AgentFinderExtension extends FinderExtension {
  @override
  String get finderType => 'Agent';

  @override
  SerializableFinder deserialize(
    Map<String, String> params,
    DeserializeFinderFactory finderFactory,
  ) {
    return AgentFinder(
      by: params['by'] ?? '',
      value: params['value'] ?? '',
      index: int.tryParse(params['index'] ?? '0') ?? 0,
      hittable: params['hittable'] == 'true',
    );
  }

  @override
  Finder createFinder(
    SerializableFinder finder,
    CreateFinderFactory finderFactory,
  ) => agentFinder(finder as AgentFinder);
}

/// Registers the `ext.chuk.agent.*` service extensions.
void registerAgentServiceExtensions() {
  developer.registerExtension('ext.chuk.agent.screenshot', (
    String method,
    Map<String, String> params,
  ) async {
    try {
      final double ratio = double.tryParse(params['pixelRatio'] ?? '') ?? 1.0;
      await freshFrame();
      final ui.Image image = await captureApp(pixelRatio: ratio);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('PNG encoding failed');
        return developer.ServiceExtensionResponse.result(
          jsonEncode(<String, Object>{
            'width': image.width,
            'height': image.height,
            'png': base64Encode(data.buffer.asUint8List()),
          }),
        );
      } finally {
        image.dispose();
      }
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        'screenshot failed: $e',
      );
    }
  });

  developer.registerExtension('ext.chuk.agent.state', (
    String method,
    Map<String, String> params,
  ) async {
    try {
      final bool all = params['includeHidden'] == 'true';
      await freshFrame();
      return developer.ServiceExtensionResponse.result(
        jsonEncode(collectUiState(includeHidden: all)),
      );
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        'state failed: $e',
      );
    }
  });

  developer.registerExtension('ext.chuk.agent.focus', (
    String method,
    Map<String, String> params,
  ) async {
    try {
      final String found = focusTextField(
        AgentFinder(
          by: params['by'] ?? '',
          value: params['value'] ?? '',
          index: int.tryParse(params['index'] ?? '0') ?? 0,
        ),
      );
      return developer.ServiceExtensionResponse.result(
        jsonEncode(<String, String>{'focused': found}),
      );
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        'focus failed: $e',
      );
    }
  });

  developer.registerExtension('ext.chuk.agent.tapAt', (
    String method,
    Map<String, String> params,
  ) async {
    final double? x = double.tryParse(params['x'] ?? '');
    final double? y = double.tryParse(params['y'] ?? '');
    if (x == null || y == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.invalidParams,
        'tapAt needs numeric x and y (logical pixels)',
      );
    }
    await tapAt(Offset(x, y));
    return developer.ServiceExtensionResponse.result('{"ok":true}');
  });
}

/// Forces one frame and waits for it, so the layers show the current state.
///
/// Without it, a capture right after a driver command can show the frame
/// before the command: under xvfb the engine does not always draw a new
/// frame at once. Gives up after [timeout] (for example when the window is
/// hidden and the engine draws no frames).
Future<void> freshFrame({
  Duration timeout = const Duration(seconds: 3),
}) async {
  SchedulerBinding.instance.scheduleForcedFrame();
  await SchedulerBinding.instance.endOfFrame.timeout(
    timeout,
    onTimeout: () {},
  );
}

/// Renders the whole app (every route, dialog and overlay) to an image.
///
/// Uses the root boundary of `lib/main.dart`. Before the app has built it,
/// falls back to the layer of the first render view.
Future<ui.Image> captureApp({double pixelRatio = 1.0}) async {
  final RenderObject? ro = appCaptureBoundaryKey.currentContext
      ?.findRenderObject();
  if (ro is RenderRepaintBoundary && ro.debugLayer != null) {
    return ro.toImage(pixelRatio: pixelRatio);
  }
  final RenderView view = RendererBinding.instance.renderViews.first;
  // ignore: invalid_use_of_protected_member
  final OffsetLayer layer = view.layer! as OffsetLayer;
  return layer.toImage(view.paintBounds, pixelRatio: pixelRatio);
}

/// Gives the focus to the text field that [f] names: the field inside the
/// match, or the field around it (for example a hint text). A focused field
/// opens its text input connection, so the driver `enter_text` command types
/// into it. Returns a short description of the field.
String focusTextField(AgentFinder f) {
  final Finder match = agentFinder(f);
  final List<Element> hits = match.evaluate().toList();
  if (hits.isEmpty) throw StateError('no widget for ${f.by}="${f.value}"');
  // The field inside the match, else the nearest field around it: walk up
  // and search each ancestor. A hint text is a sibling of its EditableText.
  final EditableText? field =
      _findEditable(hits.first) ?? _nearestEditable(hits.first);
  final EditableText? target = field;
  if (target == null) {
    throw StateError('${f.by}="${f.value}" is not in or around a text field');
  }
  target.focusNode.requestFocus();
  return 'EditableText(${target.controller.text.length} chars)';
}

EditableText? _findEditable(Element root) {
  if (root.widget is EditableText) return root.widget as EditableText;
  EditableText? found;
  void visit(Element e) {
    if (found != null) return;
    if (e.widget is EditableText) {
      found = e.widget as EditableText;
      return;
    }
    e.visitChildren(visit);
  }

  root.visitChildren(visit);
  return found;
}

EditableText? _nearestEditable(Element start) {
  EditableText? found;
  start.visitAncestorElements((Element e) {
    found = _findEditable(e);
    return found == null;
  });
  return found;
}

int _nextPointer = 900;

/// Sends one tap (pointer down, pointer up) at [position] in logical pixels.
Future<void> tapAt(Offset position) async {
  final TestPointer pointer = TestPointer(_nextPointer++);
  GestureBinding.instance.handlePointerEvent(pointer.down(position));
  await Future<void>.delayed(const Duration(milliseconds: 60));
  GestureBinding.instance.handlePointerEvent(pointer.up());
}

/// What the agent can see now: texts, tooltips, semantics identifiers, icons
/// and text fields, each with its rectangle in logical pixels.
///
/// Without [includeHidden], an entry is listed only when a tap at its centre
/// reaches it, so widgets under a route or a dialog are left out.
Map<String, Object?> collectUiState({bool includeHidden = false}) {
  final RenderView view = RendererBinding.instance.renderViews.first;
  final Size size = view.size;
  final List<Map<String, Object?>> texts = <Map<String, Object?>>[];
  final List<Map<String, Object?>> tooltips = <Map<String, Object?>>[];
  final List<Map<String, Object?>> semantics = <Map<String, Object?>>[];
  final List<Map<String, Object?>> icons = <Map<String, Object?>>[];
  final List<Map<String, Object?>> fields = <Map<String, Object?>>[];

  void visit(Element element) {
    final Widget w = element.widget;
    if (w is RichText) {
      final String t = w.text.toPlainText().trim();
      if (t.isNotEmpty && !_isIconGlyph(t)) {
        _add(texts, element, size, includeHidden, <String, Object?>{'text': t});
      }
    } else if (w is Tooltip && (w.message ?? '').isNotEmpty) {
      _add(tooltips, element, size, includeHidden, <String, Object?>{
        'tooltip': w.message,
      });
    } else if (w is Semantics && w.properties.identifier != null) {
      _add(semantics, element, size, includeHidden, <String, Object?>{
        'id': w.properties.identifier,
        if (w.properties.label != null) 'label': w.properties.label,
      });
    } else if (w is AppIcon || w is Icon) {
      final IconData? icon = w is AppIcon ? w.icon : (w as Icon).icon;
      if (icon != null) {
        _add(icons, element, size, includeHidden, <String, Object?>{
          'codePoint': '0x${icon.codePoint.toRadixString(16)}',
        });
      }
    } else if (w is EditableText) {
      _add(fields, element, size, includeHidden, <String, Object?>{
        // Never send a password to the agent transcript.
        'value': w.obscureText
            ? '*' * w.controller.text.length
            : w.controller.text,
        'focused': w.focusNode.hasFocus,
        'obscured': w.obscureText,
      });
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return <String, Object?>{
    'window': <String, double>{'width': size.width, 'height': size.height},
    'texts': texts,
    'tooltips': tooltips,
    'semantics': semantics,
    'icons': icons,
    'fields': fields,
  };
}

bool _isIconGlyph(String t) =>
    t.runes.length == 1 && t.runes.first >= 0xE000 && t.runes.first <= 0xF8FF;

void _add(
  List<Map<String, Object?>> out,
  Element element,
  Size window,
  bool includeHidden,
  Map<String, Object?> entry,
) {
  final RenderObject? ro = element.renderObject;
  if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
  final Offset topLeft = ro.localToGlobal(Offset.zero);
  final Rect rect = topLeft & ro.size;
  final bool onScreen =
      rect.width > 0 && rect.height > 0 && rect.overlaps(Offset.zero & window);
  final bool hit = onScreen && _receivesTapAt(ro, rect.center);
  if (!includeHidden && !hit) return;
  out.add(<String, Object?>{
    ...entry,
    'rect': <String, int>{
      'x': rect.left.round(),
      'y': rect.top.round(),
      'w': rect.width.round(),
      'h': rect.height.round(),
    },
    if (includeHidden) 'hittable': hit,
  });
}

bool _receivesTapAt(RenderBox box, Offset position) {
  final HitTestResult result = HitTestResult();
  final RenderView view = RendererBinding.instance.renderViews.first;
  RendererBinding.instance.hitTestInView(
    result,
    position,
    view.flutterView.viewId,
  );
  for (final HitTestEntry entry in result.path) {
    if (entry.target == box) return true;
  }
  return false;
}
