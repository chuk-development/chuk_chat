// Walks every screen of the running app and hits every button, as fast as
// the app takes it. For each tap: time to the next frame, worst frame,
// exceptions, error widgets, and duplicate routes from rapid taps. Rows go to
// logcat as `PERFBENCH {"crawl":...}`. See docs/PERFORMANCE.md.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ErrorCallback, FramePhase, FrameTiming, PlatformDispatcher;
import 'dart:developer' show Timeline;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'bench_guard.dart';

/// These end the session, so the crawl would stop. Reported as skipped.
final RegExp _sessionEnders = RegExp(
  r'sign ?out|log ?out|abmelden|delete (my )?account|konto l.schen|'
  r'delete all|alle .*l.schen',
  caseSensitive: false,
);

class _Frame {
  _Frame(FrameTiming t)
    : startUs = t.timestampInMicroseconds(FramePhase.vsyncStart),
      endUs = t.timestampInMicroseconds(FramePhase.rasterFinish),
      buildMs = t.buildDuration.inMicroseconds / 1000,
      rasterMs = t.rasterDuration.inMicroseconds / 1000;

  final int startUs;
  final int endUs;
  final double buildMs;
  final double rasterMs;
}

class _Target {
  _Target(this.label, this.at, this.element, {required this.longPress});

  final String label;
  final Offset at;
  final Element element;
  final bool longPress;
}

class _Action {
  _Action(this.screen, this.label, this.kind, this.startUs);

  final String screen;
  final String label;
  final String kind;
  final int startUs;
  int endUs = 0;
  int depthDelta = 0;
  int stallMs = 0;
  bool settled = true;
  String to = '';
  final List<String> problems = <String>[];
}

class Crawler {
  Crawler({required this.budget, required this.emit});

  final Duration budget;
  final void Function(Map<String, Object?>) emit;

  final List<_Frame> _frames = <_Frame>[];
  final List<_Action> _actions = <_Action>[];
  final Set<String> _visited = <String>{};
  final Set<String> _skipped = <String>{};
  final Stopwatch _clock = Stopwatch();
  /// The screen name of the root: what is on top of the shell right now.
  String _tag = 'shell';
  _Action? _current;
  Timer? _ticker;
  int _lastTickUs = 0;
  int _pointer = 3000;
  Duration _stamp = const Duration(seconds: 5000);

  bool get _outOfTime => _clock.elapsed > budget || _clock.elapsed > _rootEnd;

  /// The end of the current root; one root must not eat the whole budget.
  Duration _rootEnd = Duration.zero;

  final Map<String, int> _perScreen = <String, int>{};
  static const int _screenLimit = 24;

  /// Targets that this root leaves alone, by label.
  RegExp? _skip;

  Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  void _problem(String text) {
    final String short = text.length > 300 ? text.substring(0, 300) : text;
    final _Action? a = _current;
    if (a != null) {
      a.problems.add(short);
    } else {
      emit(<String, Object?>{
        'crawl_problem': short,
        'screen': 'between actions',
      });
    }
  }

  /// A hang is a UI isolate that does not get to run: the longest gap of a
  /// 8 ms timer during the action.
  void _tick(Timer _) {
    final int now = Timeline.now;
    final int gap = (now - _lastTickUs) ~/ 1000;
    _lastTickUs = now;
    final _Action? a = _current;
    if (a != null && gap > a.stallMs) a.stallMs = gap;
  }

  /// Until no frame is due for 150 ms. An endless animation hits the limit.
  Future<void> _settle(_Action a) async {
    final Stopwatch w = Stopwatch()..start();
    final Stopwatch quiet = Stopwatch()..start();
    while (quiet.elapsedMilliseconds < 150) {
      if (w.elapsedMilliseconds > 2500) {
        a.settled = false;
        return;
      }
      await _wait(8);
      if (SchedulerBinding.instance.hasScheduledFrame ||
          SchedulerBinding.instance.transientCallbackCount > 0) {
        quiet.reset();
      }
    }
  }

  void start() {
    // After the app's own observer: they are asked in the order they came.
    keepAppOnRootBack();
    _clock.start();
    _lastTickUs = Timeline.now;
    _ticker = Timer.periodic(const Duration(milliseconds: 8), _tick);
    SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> t) {
      _frames.addAll(t.map(_Frame.new));
    });
    final FlutterExceptionHandler? flutter = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails d) {
      _problem('exception: ${d.exceptionAsString()}');
      flutter?.call(d);
    };
    final ErrorCallback? platform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object e, StackTrace s) {
      final String top = s
          .toString()
          .split('\n')
          .where((String l) => l.contains('package:chuk_chat'))
          .take(3)
          .join(' < ');
      _problem('async: ${e.runtimeType} ${e.toString().split(',').first} at $top');
      return platform?.call(e, s) ?? true;
    };
  }

  void _walk(Element root, bool Function(Element) visit) {
    void go(Element e) {
      if (visit(e)) e.visitChildElements(go);
    }

    go(root);
  }

  /// The routes in the tree, of every navigator.
  List<Element> _routes() {
    final List<Element> out = <Element>[];
    final Element? root = WidgetsBinding.instance.rootElement;
    if (root == null) return out;
    _walk(root, (Element e) {
      if (e.widget.runtimeType.toString().startsWith('_ModalScope<')) out.add(e);
      return true;
    });
    return out;
  }

  int get _depth => _routes().length;

  bool _hasErrorWidget() {
    bool hit = false;
    final Element? root = WidgetsBinding.instance.rootElement;
    if (root == null) return false;
    _walk(root, (Element e) {
      if (e.widget is ErrorWidget) hit = true;
      return !hit;
    });
    return hit;
  }

  String _screen() {
    final List<Element> routes = _routes();
    if (routes.isEmpty) return 'root';
    final RegExp named = RegExp(
      r'(Page|Screen|Sheet|Dialog|Picker|Shell|Menu|Choice|Panel|Editor)$',
    );
    String? name;
    _walk(routes.last, (Element e) {
      final String t = e.widget.runtimeType.toString();
      if (name == null && named.hasMatch(t) && !t.contains('Modal')) name = t;
      return name == null;
    });
    if (name == 'MessengerShell') return _tag;
    return name ?? routes.last.widget.runtimeType.toString();
  }

  /// The nearest app widget above [e], which names a button without text.
  String _owner(Element e) {
    final RegExp app = RegExp(
      r'(Block|Card|Bubble|Button|Row|Item|Chip|Pill|Bar|Tile|Menu|Action|'
      r'Table|Code|Tool|Reasoning|Actions|Selector|Input|Header|Sidebar|Mobile)',
    );
    final RegExp framework = RegExp(
      r'^_?(Icon|Text|Elevated|Filled|Outlined|Tab|App|Inherited|Scroll|Sliver)'
      r'|Ink|Material|Render|Semantics|Actions|Focus',
    );
    String? hit;
    int left = 24;
    e.visitAncestorElements((Element a) {
      final String t = a.widget.runtimeType.toString().split('<').first;
      if (app.hasMatch(t) && !framework.hasMatch(t)) hit = t;
      return hit == null && --left > 0;
    });
    return hit ?? 'unnamed';
  }

  String _label(Element e) {
    String? text;
    IconData? icon;
    String? tip;
    _walk(e, (Element c) {
      final Widget w = c.widget;
      if (text == null && w is RichText) {
        final String s = w.text.toPlainText().trim();
        if (s.isNotEmpty) text = s;
      }
      if (w is Icon) icon ??= w.icon;
      if (w is Tooltip && (w.message ?? '').isNotEmpty) tip ??= w.message;
      return text == null;
    });
    String l = text ?? tip ?? '';
    if (l.isEmpty && icon != null) {
      l = 'icon:${icon!.codePoint.toRadixString(16)}';
    }
    if (l.isEmpty) {
      // A bare icon: its place tells it from its neighbours.
      final RenderObject? r = e.findRenderObject();
      final Offset at = r is RenderBox
          ? r.localToGlobal(Offset.zero)
          : Offset.zero;
      return '${_owner(e)} at:${at.dx ~/ 16}x${at.dy ~/ 16}';
    }
    l = l.replaceAll(RegExp(r'\d+'), '#').replaceAll('\n', ' ');
    return l.length > 48 ? l.substring(0, 48) : l;
  }

  /// Every tappable thing a finger can really reach now.
  List<_Target> _targets() {
    final List<_Target> out = <_Target>[];
    final List<Element> routes = _routes();
    if (routes.isEmpty) return out;
    final FlutterView view = PlatformDispatcher.instance.views.first;
    final Size screen = view.physicalSize / view.devicePixelRatio;
    final Set<String> seen = <String>{};
    _walk(routes.last, (Element e) {
      final Widget w = e.widget;
      if (w is! GestureDetector) return true;
      final bool tap = w.onTap != null;
      final bool long = w.onLongPress != null;
      if (!tap && !long) return true;
      final RenderObject? r = e.findRenderObject();
      if (r is! RenderBox || !r.hasSize || !r.attached) return true;
      final Offset at = r.localToGlobal(r.size.center(Offset.zero));
      if (at.dx < 0 || at.dy < 0 || at.dx > screen.width || at.dy > screen.height) {
        return true;
      }
      final HitTestResult hit = HitTestResult();
      WidgetsBinding.instance.hitTestInView(hit, at, view.viewId);
      if (!hit.path.any((HitTestEntry h) => identical(h.target, r))) return true;
      final String label = _label(e);
      if (tap && seen.add('t$label')) {
        out.add(_Target(label, at, e, longPress: false));
      }
      if (long && seen.add('l$label')) {
        out.add(_Target(label, at, e, longPress: true));
      }
      return true;
    });
    return out;
  }

  Future<void> _tap(Offset at, {int holdMs = 20}) async {
    final int p = _pointer++;
    _stamp += const Duration(milliseconds: 200);
    GestureBinding.instance.handlePointerEvent(
      PointerDownEvent(pointer: p, position: at, timeStamp: _stamp),
    );
    await _wait(holdMs);
    _stamp += Duration(milliseconds: holdMs);
    GestureBinding.instance.handlePointerEvent(
      PointerUpEvent(pointer: p, position: at, timeStamp: _stamp),
    );
  }

  /// One back, and the wait until its route is really out of the tree. Its
  /// exit transition keeps it there; a second back would take the parent.
  Future<void> _back() async {
    final int before = _depth;
    await WidgetsBinding.instance.handlePopRoute();
    final Stopwatch w = Stopwatch()..start();
    while (_depth >= before && w.elapsedMilliseconds < 800) {
      await _wait(16);
    }
  }

  Future<void> _returnTo(int depth) async {
    for (int i = 0; i < 8 && _depth > depth; i++) {
      await _back();
    }
    if (_depth > depth) _problem('stuck: back did not leave ${_screen()}');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  /// A button may have opened a system screen; the script closes it.
  Future<void> _awaitFront() async {
    final Stopwatch w = Stopwatch()..start();
    while (WidgetsBinding.instance.lifecycleState !=
            AppLifecycleState.resumed &&
        w.elapsedMilliseconds < 15000) {
      await _wait(100);
    }
  }

  Future<void> _act(_Target t, {required bool descend, required int level}) async {
    await _awaitFront();
    await _flush(olderThanUs: Timeline.now - 1500000);
    final String screen = _screen();
    final int before = _depth;

    // One tap at normal speed, the frame cost of this button.
    final _Action one = _Action(
      screen,
      t.label,
      t.longPress ? 'long' : 'tap',
      Timeline.now,
    );
    _current = one;
    await _tap(t.at, holdMs: t.longPress ? 560 : 20);
    await _settle(one);
    one.endUs = Timeline.now;
    one.depthDelta = _depth - before;
    one.to = _screen();
    if (_hasErrorWidget()) one.problems.add('error widget on screen');
    _actions.add(one);
    await _awaitFront();

    if (one.depthDelta > 0 && descend && level < 6) {
      await crawlHere(level + 1);
    }
    _current = one;
    await _returnTo(before);
    await _wait(60);
    if (t.longPress || !t.element.mounted) {
      _current = null;
      return;
    }

    // Rapid fire on the same spot: duplicate routes, disposed state.
    final _Action rapid = _Action(screen, t.label, 'rapid', Timeline.now);
    _current = rapid;
    for (int i = 0; i < 5; i++) {
      await _tap(t.at, holdMs: 8);
      await _wait(8);
    }
    await _settle(rapid);
    rapid.endUs = Timeline.now;
    rapid.to = _screen();
    rapid.depthDelta = _depth - before;
    if (rapid.depthDelta > 1) {
      rapid.problems.add('${rapid.depthDelta} routes from rapid taps');
    }
    if (_hasErrorWidget()) rapid.problems.add('error widget on screen');
    _actions.add(rapid);
    await _awaitFront();
    await _returnTo(before);

    // Tap and back at once: the route goes while it is still arriving.
    if (one.depthDelta > 0 && t.element.mounted) {
      final _Action race = _Action(screen, t.label, 'tapback', Timeline.now);
      _current = race;
      await _tap(t.at, holdMs: 8);
      await _wait(16);
      // Only over a route of its own: at the root, back closes the app.
      if (_depth > before) await WidgetsBinding.instance.handlePopRoute();
      await _settle(race);
      race.endUs = Timeline.now;
      race.to = _screen();
      race.depthDelta = _depth - before;
      if (_hasErrorWidget()) race.problems.add('error widget on screen');
      _actions.add(race);
      await _returnTo(before);
    }
    _current = null;
  }

  /// All targets of the screen in front, then its scrolled parts.
  ///
  /// [setup] brings the screen back to where this crawl started, before every
  /// action: a tap may close the sidebar or open another chat.
  Future<void> crawlHere(
    int level, {
    Future<void> Function()? setup,
    String? tag,
    Duration? rootBudget,
    RegExp? skip,
  }) async {
    if (tag != null) _tag = tag;
    if (rootBudget != null) _rootEnd = _clock.elapsed + rootBudget;
    if (level == 0) _skip = skip;
    await setup?.call();
    final String screen = _screen();
    final int depth = _depth;
    for (int scrolls = 0; scrolls < 40; scrolls++) {
      while (!_outOfTime) {
        await setup?.call();
        // The page closed itself. Its parent goes on, with its own setup.
        if (_depth < depth) return;
        // The back arrow last: it closes the page the rest of the list is on.
        final List<_Target> all = _targets()
          ..sort((_Target x, _Target y) {
            bool back(_Target t) => level > 0 && t.at.dx < 64 && t.at.dy < 110;
            return (back(x) ? 1 : 0) - (back(y) ? 1 : 0);
          });
        _Target? next;
        for (final _Target t in all) {
          final String sig = '$screen|${t.longPress ? 'L' : 'T'}|${t.label}';
          if (_visited.contains(sig)) continue;
          if (_skip?.hasMatch(t.label) ?? false) continue;
          if (_sessionEnders.hasMatch(t.label)) {
            if (_skipped.add('$screen: ${t.label}')) {
              emit(<String, Object?>{'crawl_skip': '$screen: ${t.label}'});
            }
            _visited.add(sig);
            continue;
          }
          _visited.add(sig);
          next = t;
          break;
        }
        if (next == null) break;
        // A page can ask for a system permission again on every resume and
        // hold the crawl there. The limit moves it on.
        final int done = _perScreen[screen] = (_perScreen[screen] ?? 0) + 1;
        if (level > 0 && done > _screenLimit) return;
        await _act(next, descend: true, level: level);
        await _returnTo(depth);
      }
      if (_outOfTime || !await _scrollOn()) break;
    }
  }

  /// Moves the largest scrollable on the screen on by one page.
  Future<bool> _scrollOn() async {
    final List<Element> routes = _routes();
    if (routes.isEmpty) return false;
    ScrollPosition? best;
    double area = 0;
    _walk(routes.last, (Element e) {
      if (e is StatefulElement && e.state is ScrollableState) {
        final ScrollableState s = e.state as ScrollableState;
        final RenderObject? r = e.findRenderObject();
        if (r is RenderBox && r.hasSize && s.position.hasContentDimensions) {
          final double a = r.size.width * r.size.height;
          if (a > area && s.position.extentAfter > 1) {
            area = a;
            best = s.position;
          }
        }
      }
      return true;
    });
    final ScrollPosition? p = best;
    if (p == null) return false;
    p.jumpTo(p.pixels + p.viewportDimension * .8);
    await _wait(140);
    return true;
  }

  double _pctl(List<double> s, double q) =>
      s.isEmpty ? 0 : s[((s.length - 1) * q).round()];

  int _flushed = 0;

  /// Writes the rows of actions whose frames have arrived. Timings come late,
  /// in batches, so the newest actions wait for the next call.
  Future<void> _flush({required int olderThanUs}) async {
    while (_flushed < _actions.length) {
      final _Action a = _actions[_flushed];
      if (a.endUs == 0 || a.endUs > olderThanUs) return;
      _flushed++;
      final Iterable<_Frame> f = _frames.where(
        (x) => x.startUs >= a.startUs && x.startUs <= a.endUs,
      );
      double build = 0, raster = 0;
      int firstEnd = 0, lastEnd = 0, jank = 0;
      double worst = 0;
      for (final _Frame x in f) {
        if (x.buildMs > build) build = x.buildMs;
        if (x.rasterMs > raster) raster = x.rasterMs;
        if (firstEnd == 0 || x.endUs < firstEnd) firstEnd = x.endUs;
        if (x.endUs > lastEnd) lastEnd = x.endUs;
        final double total = (x.endUs - x.startUs) / 1000;
        if (total > worst) worst = total;
        if (total > 16.67) jank++;
      }
      emit(<String, Object?>{
        'crawl': jsonEncode(<String, Object?>{
          's': a.screen,
          'l': a.label,
          'k': a.kind,
          'to': a.to,
          'first': firstEnd == 0 ? null : (firstEnd - a.startUs) ~/ 1000,
          'settled': lastEnd == 0 ? null : (lastEnd - a.startUs) ~/ 1000,
          'worst': worst.round(),
          'jank': jank,
          'stall': a.stallMs,
          'quiet': a.settled,
          'build': build.round(),
          'raster': raster.round(),
          'n': f.length,
          'd': a.depthDelta,
          'p': a.problems,
        }),
      });
    }
    // Later rows only look at later frames.
    final int keepFrom = _flushed < _actions.length
        ? _actions[_flushed].startUs
        : olderThanUs;
    _frames.removeWhere((x) => x.startUs < keepFrom);
  }

  /// The last rows, and the end marker.
  Future<void> report() async {
    _ticker?.cancel();
    await _wait(1500);
    await _flush(olderThanUs: Timeline.now);
    final List<double> builds = _frames.map((x) => x.buildMs).toList()..sort();
    emit(<String, Object?>{
      'crawl_done': true,
      'actions': _actions.length,
      'build_p99_tail': _pctl(builds, .99),
      'elapsed_s': _clock.elapsed.inSeconds,
    });
  }
}
