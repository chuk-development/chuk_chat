// Phone benchmark. The REAL app (`app.main()`), a fake signed-in session and
// a real SQLite cache full of synthetic chats, driven from inside the app
// through the real gesture and text input paths, with the real soft keyboard.
// Results go to logcat as `PERFBENCH <json>` lines; scripts/perf_bench.sh
// reads them and prints the table. See docs/PERFORMANCE.md.
//
// Never run this entry on the app's own package: the script installs it as
// `dev.chuk.chat.perf`, next to the owner's app, with its own data.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show debugProfileLayoutsEnabled, debugProfilePaintsEnabled;
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show SemanticsBinding, SemanticsHandle;
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'package:chuk_chat/main.dart' as app;
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';
import 'package:chuk_chat/platform_specific/sidebar_mobile.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

import 'perf_bench/bench_agents.dart';
import 'perf_bench/bench_crawler.dart';
import 'perf_bench/bench_fixture.dart';
import 'perf_bench/bench_guard.dart';
import 'perf_bench/bench_stream.dart';

const String _userId = '00000000-0000-4000-8000-000000000042';
const String _email = 'bench@example.invalid';

/// Rebuild census runs only with this define: widget timeline events slow
/// every frame, so the timing run must not carry them.
const bool _census = bool.fromEnvironment('BENCH_CENSUS');

/// The phone had accessibility services on (Sprecho, Bitwarden), and with
/// any service on, the engine keeps the semantics tree alive. The AVD has
/// none, so this holds it open to match. See docs/PERFORMANCE.md.
const bool _semantics = bool.fromEnvironment(
  'BENCH_SEMANTICS',
  defaultValue: true,
);
// Held for the whole run; dropping it ends the semantics tree.
// ignore: unused_element
SemanticsHandle? _semanticsHandle;

/// `bench` (default), `crawl` (chat half) or `crawl-agents`.
const String _mode = String.fromEnvironment('BENCH_MODE', defaultValue: 'bench');

/// With names of single widgets. Fills the timeline buffer fast, so a phase
/// only keeps its last frames; without it, the frame phases of all of it.
const bool _censusWidgets = bool.fromEnvironment('BENCH_CENSUS_WIDGETS');

void emit(Map<String, Object?> row) {
  // ignore: avoid_print
  print('PERFBENCH ${jsonEncode(row)}');
}

String _fakeJwt() {
  String b64(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final int exp =
      DateTime.now().add(const Duration(days: 300)).millisecondsSinceEpoch ~/
      1000;
  return '${b64({'alg': 'none'})}.'
      '${b64({'sub': _userId, 'exp': exp, 'email': _email, 'role': 'authenticated'})}.bench';
}

/// A session gotrue accepts offline. The host is 127.0.0.1:9, nothing answers.
Future<void> _signInOffline() async {
  await SupabaseService.initialize();
  if (SupabaseService.auth.currentSession != null) return;
  final String token = _fakeJwt();
  final int exp =
      DateTime.now().add(const Duration(days: 300)).millisecondsSinceEpoch ~/
      1000;
  await SupabaseService.auth.recoverSession(
    jsonEncode(<String, Object?>{
      'access_token': token,
      'refresh_token': 'bench-refresh',
      'token_type': 'bearer',
      'expires_in': 25920000,
      'expires_at': exp,
      'user': <String, Object?>{
        'id': _userId,
        'aud': 'authenticated',
        'email': _email,
        'app_metadata': <String, Object?>{},
        'user_metadata': <String, Object?>{},
        'created_at': '2026-01-01T00:00:00Z',
      },
    }),
  );
}

Future<void> _seed() async {
  final DateTime base = DateTime.now().toUtc();
  int order = 0;
  Future<void> put(String id, String title, int count) {
    final String at = base
        .add(Duration(seconds: order++))
        .toIso8601String();
    return LocalChatCacheService.upsert(
      _userId,
      LocalChatCacheService.buildPlaintextRow(
        id: id,
        payload: encodeChatPayload(benchMessages(count)),
        createdAt: at,
        isStarred: false,
        updatedAt: at,
        title: title,
      ),
    );
  }

  // Newest last: the sidebar sorts by date and builds its rows lazily, so
  // the two chats the scenario taps must sit at the top.
  for (int i = 0; i < 120; i++) {
    await put(
      // A chuk chat id is a UUID; anything else counts as an Agents thread.
      '33333333-3333-4333-8333-${i.toString().padLeft(12, '0')}',
      'Sidebar chat number $i',
      2,
    );
  }
  await put(kBenchShortChatId, kBenchShortTitle, 6);
  await put(kBenchLongChatId, kBenchLongTitle, 300);
  // The model list comes from the API, which the guard blocks.
  await ModelCacheService.saveAvailableModels(<Map<String, dynamic>>[
    for (final String id in <String>[
      'deepseek/deepseek-v4-flash-0731',
      'deepseek/deepseek-v4-pro-0813',
      'z-ai/glm-5.3-flash',
    ])
      <String, dynamic>{'id': id, 'name': id.split('/').last},
  ]);
  await ModelCacheService.saveSelectedModel(
    _userId,
    'deepseek/deepseek-v4-flash-0731',
  );
}

Future<void> main() async {
  final int mainAt = DateTime.now().millisecondsSinceEpoch;
  WidgetsFlutterBinding.ensureInitialized();
  installBenchGuard();
  if (_semantics) {
    _semanticsHandle = SemanticsBinding.instance.ensureSemantics();
  }
  debugProfileBuildsEnabled = _censusWidgets;
  debugProfileBuildsEnabledUserWidgets = _censusWidgets;
  debugProfileLayoutsEnabled = _censusWidgets;
  debugProfilePaintsEnabled = _censusWidgets;

  if (_mode == 'crawl-agents') {
    await crawlAgents(emit);
    return;
  }

  final Directory dir = await getApplicationDocumentsDirectory();
  final File marker = File('${dir.path}/bench_seeded');
  final bool seeded = marker.existsSync();

  if (!seeded) {
    await _signInOffline();
    await _seed();
    marker.writeAsStringSync('1');
  }
  installBenchStream();
  final _Runner runner = _Runner(mainAt);
  unawaited(
    _mode == 'crawl'
        ? runner.crawl()
        : seeded && !_forceRun(dir)
        ? runner.coldOnly()
        : runner.all(),
  );
  await app.main();
}

bool _forceRun(Directory dir) {
  final File f = File('${dir.path}/bench_force');
  if (!f.existsSync()) return false;
  f.deleteSync();
  return true;
}

class _Frame {
  _Frame(FrameTiming t)
    : vsyncUs = t.timestampInMicroseconds(FramePhase.vsyncStart),
      buildMs = t.buildDuration.inMicroseconds / 1000,
      rasterMs = t.rasterDuration.inMicroseconds / 1000,
      totalMs = t.totalSpan.inMicroseconds / 1000;

  final int vsyncUs;
  final double buildMs;
  final double rasterMs;
  final double totalMs;
}

double _pct(List<double> sorted, double q) =>
    sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * q).round()];

class _Stats {
  final List<_Frame> frames = <_Frame>[];
  final List<double> wallMs = <double>[];
  final List<double> extra = <double>[];
  int insetSteps = 0;

  Map<String, Object?> json(String name, String note) {
    double r(double v) => (v * 100).round() / 100;
    final List<double> b = frames.map((f) => f.buildMs).toList()..sort();
    final List<double> ra = frames.map((f) => f.rasterMs).toList()..sort();
    final List<double> t = frames.map((f) => f.totalMs).toList()..sort();
    final List<double> w = List<double>.of(wallMs)..sort();
    return <String, Object?>{
      'phase': name,
      'note': note,
      'frames': frames.length,
      'build_p50': r(_pct(b, .5)),
      'build_p90': r(_pct(b, .9)),
      'build_p99': r(_pct(b, .99)),
      'build_max': r(_pct(b, 1)),
      'raster_p50': r(_pct(ra, .5)),
      'raster_p90': r(_pct(ra, .9)),
      'raster_p99': r(_pct(ra, .99)),
      'raster_max': r(_pct(ra, 1)),
      'total_p50': r(_pct(t, .5)),
      'total_p99': r(_pct(t, .99)),
      'total_max': r(_pct(t, 1)),
      'jank_16ms': t.where((v) => v > 16.67).length,
      'jank_33ms': t.where((v) => v > 33.3).length,
      'wall_med': r(_pct(w, .5)),
      'wall_max': r(_pct(w, 1)),
      'n': w.length,
      'inset_steps': insetSteps,
    };
  }
}

class _Runner {
  _Runner(this.mainAt) {
    SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> t) {
      _all.addAll(t.map(_Frame.new));
    });
  }

  final int mainAt;
  final List<_Frame> _all = <_Frame>[];

  double get _inset =>
      PlatformDispatcher.instance.views.first.viewInsets.bottom;

  Element? _find(bool Function(Element) test) {
    Element? hit;
    void walk(Element e) {
      if (hit != null) return;
      if (test(e)) {
        hit = e;
        return;
      }
      e.visitChildElements(walk);
    }

    final Element? root = WidgetsBinding.instance.rootElement;
    if (root != null) walk(root);
    return hit;
  }

  ChukChatUIMobileState? _chat() {
    final Element? e = _find(
      (e) => e is StatefulElement && e.state is ChukChatUIMobileState,
    );
    return (e as StatefulElement?)?.state as ChukChatUIMobileState?;
  }

  EditableTextState? _editable() {
    final ChukChatUIMobileState? chat = _chat();
    if (chat == null) return null;
    Element? hit;
    void walk(Element e) {
      if (hit != null) return;
      if (e is StatefulElement && e.state is EditableTextState) {
        final EditableTextState s = e.state as EditableTextState;
        if (identical(s.widget.focusNode, chat.composerFocusNode)) {
          hit = e;
          return;
        }
      }
      e.visitChildElements(walk);
    }

    chat.context.visitChildElements(walk);
    return (hit as StatefulElement?)?.state as EditableTextState?;
  }

  Offset? _textCenter(String text) {
    final Element? e = _find((e) {
      final Widget w = e.widget;
      return w is RichText && w.text.toPlainText() == text;
    });
    final RenderObject? r = e?.renderObject;
    if (r is! RenderBox || !r.hasSize) return null;
    return r.localToGlobal(r.size.center(Offset.zero));
  }

  int _pointer = 900;
  Duration _touchClock = const Duration(seconds: 1000);

  void _touch(PointerEvent e) => GestureBinding.instance.handlePointerEvent(e);

  Future<void> _tap(Offset at) async {
    final int p = _pointer++;
    _touchClock += const Duration(milliseconds: 40);
    _touch(PointerDownEvent(pointer: p, position: at, timeStamp: _touchClock));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _touchClock += const Duration(milliseconds: 40);
    _touch(PointerUpEvent(pointer: p, position: at, timeStamp: _touchClock));
  }

  /// Moves a finger once per frame until [frames] are done.
  Future<void> _drag(Offset from, Offset step, int frames) async {
    final int p = _pointer++;
    Offset at = from;
    _touch(PointerDownEvent(pointer: p, position: at, timeStamp: _touchClock));
    final Completer<void> done = Completer<void>();
    int left = frames;
    void tick(Duration _) {
      if (left-- <= 0) {
        done.complete();
        return;
      }
      at += step;
      _touchClock += const Duration(milliseconds: 16);
      _touch(
        PointerMoveEvent(
          pointer: p,
          position: at,
          delta: step,
          timeStamp: _touchClock,
        ),
      );
      SchedulerBinding.instance.scheduleFrameCallback(tick);
      SchedulerBinding.instance.scheduleFrame();
    }

    SchedulerBinding.instance.scheduleFrameCallback(tick);
    SchedulerBinding.instance.scheduleFrame();
    await done.future;
    _touch(PointerUpEvent(pointer: p, position: at, timeStamp: _touchClock));
  }

  Future<void> _wait(int ms) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// Runs [body] [reps] times. Each run counts the frames from its start
  /// until 1.2 s later; the timing callback reports in batches.
  Future<void> _phase(
    String name,
    Future<void> Function() body, {
    int reps = 1,
    String note = '',
    Future<void> Function()? between,
  }) async {
    final _Stats s = _Stats();
    for (int i = 0; i < reps; i++) {
      await _wait(500);
      final int start = Timeline.now;
      final Stopwatch w = Stopwatch()..start();
      await body();
      s.wallMs.add(w.elapsedMicroseconds / 1000);
      final int end = Timeline.now;
      await _wait(1200);
      s.frames.addAll(
        _all.where((f) => f.vsyncUs >= start && f.vsyncUs <= end),
      );
      await between?.call();
    }
    s.insetSteps = _lastSteps;
    emit(s.json(name, note));
  }

  int _lastSteps = 0;

  /// Waits for the keyboard inset to reach its end and stay there. Counts the
  /// distinct values on the way, i.e. how many frames it really moved.
  Future<void> _awaitInset(bool open) async {
    final Set<double> seen = <double>{};
    int stable = 0;
    double last = _inset;
    final Stopwatch w = Stopwatch()..start();
    while (w.elapsedMilliseconds < 3000) {
      await _wait(8);
      final double v = _inset;
      seen.add(v);
      if (v != last) {
        stable = 0;
        last = v;
        continue;
      }
      stable++;
      final bool atEnd = open ? v > 100 : v == 0;
      if (atEnd && stable > 45) break;
    }
    _lastSteps = seen.length;
  }

  Future<void> _kbOpen() async {
    final EditableTextState? e = _editable();
    final RenderObject? r = e?.context.findRenderObject();
    if (r is RenderBox) {
      await _tap(r.localToGlobal(r.size.center(Offset.zero)));
    } else {
      _chat()!.composerFocusNode.requestFocus();
    }
    await _awaitInset(true);
  }

  Future<void> _kbClose() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await _awaitInset(false);
  }

  Future<void> _keyboardPhases(String label) async {
    final _Stats open = _Stats();
    final _Stats close = _Stats();
    Future<void> one(_Stats s, Future<void> Function() f) async {
      await _wait(600);
      final int start = Timeline.now;
      final Stopwatch w = Stopwatch()..start();
      await f();
      // _awaitInset holds on for 360 ms after the last change.
      s.wallMs.add(w.elapsedMicroseconds / 1000 - 360);
      final int end = Timeline.now - 360000;
      s.insetSteps = _lastSteps;
      await _wait(1200);
      s.frames.addAll(
        _all.where((f) => f.vsyncUs >= start && f.vsyncUs <= end),
      );
    }

    for (int i = 0; i < 8; i++) {
      await one(open, _kbOpen);
      await one(close, _kbClose);
    }
    emit(open.json('keyboard open, $label', 'tap to last inset change'));
    emit(close.json('keyboard close, $label', 'unfocus to last inset change'));
  }

  Future<void> _typing(String label) async {
    final EditableTextState? e = _editable();
    if (e == null) return;
    await _kbOpen();
    String text = '';
    final _Stats s = _Stats();
    for (int i = 0; i < 40; i++) {
      await _wait(120);
      final int start = Timeline.now;
      final Stopwatch w = Stopwatch()..start();
      text += i % 6 == 5 ? ' ' : 'a';
      e.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await SchedulerBinding.instance.endOfFrame;
      s.wallMs.add(w.elapsedMicroseconds / 1000);
      final int end = Timeline.now;
      await _wait(60);
      s.frames.addAll(
        _all.where((f) => f.vsyncUs >= start && f.vsyncUs <= end),
      );
    }
    await _wait(1200);
    final int settle = Timeline.now - 1500000;
    s.frames.addAll(
      _all.where(
        (f) =>
            f.vsyncUs >= settle - 40 * 180000 &&
            f.vsyncUs <= settle &&
            !s.frames.contains(f),
      ),
    );
    emit(s.json('typing, $label', 'keystroke to end of frame'));
    _chat()!.composerController.clear();
    await _kbClose();
  }

  /// The phone build of the Agents app has no sidebar: chats are switched by
  /// a swipe ([SwipeChatPager]).
  SwipeChatPager? get _pager =>
      _find((e) => e.widget is SwipeChatPager)?.widget as SwipeChatPager?;

  bool get _swipeMode => _pager != null;

  /// Opens [id] through the pager's own callback, the path a finished swipe
  /// takes.
  Future<void> _pagerSelect(String id) async {
    _pager!.onSelected(id);
    await _awaitChat(id);
  }

  /// One real sideways swipe on the chat body. [next] moves to the next
  /// chat (finger to the left).
  Future<void> _swipe({required bool next, double y = .5}) async {
    final Size s = _logical;
    final double dx = next ? -28 : 28;
    final Offset from = Offset(next ? s.width * .85 : s.width * .15, s.height * y);
    await _drag(from, Offset(dx, 0), 10);
    await _settle();
  }

  Future<void> _swipePhases() async {
    // The strip sits in the top bar, the chat body below it.
    final double stripY = (MediaQueryData.fromView(
              PlatformDispatcher.instance.views.first,
            ).viewPadding.top +
            90) /
        _logical.height;
    await _phase(
      'swipe next then back, long chat',
      () async {
        await _swipe(next: true);
        await _swipe(next: false);
      },
      reps: 4,
      note: 'finger on the chat body, 280 px in 10 frames, twice',
    );
    await _phase(
      'swipe on the strip, next then back',
      () async {
        await _swipe(next: true, y: stripY);
        await _swipe(next: false, y: stripY);
      },
      reps: 3,
      note: 'finger on the title strip',
    );
    await _phase(
      'swipe drag held, no commit',
      () async {
        final Size s = _logical;
        await _drag(Offset(s.width * .5, s.height * .5), const Offset(-2, 0), 40);
        await _settle();
      },
      reps: 3,
      note: '80 px slow, may spring back or switch',
    );
    await _pagerSelect(kBenchLongChatId);
  }

  Future<void> _openChat(String title, String id) async {
    if (_swipeMode) {
      await _pagerSelect(id);
      return;
    }
    await _sidebarOpen();
    await _wait(400);
    Offset? at = _textCenter(title);
    if (at == null) {
      // The list may sit scrolled down; its first rows are the newest chats.
      final Element? e = _find(
        (e) => e is StatefulElement && e.state is ScrollableState &&
            (e.state as ScrollableState).position.pixels > 0,
      );
      if (e != null) {
        ((e as StatefulElement).state as ScrollableState).position.jumpTo(0);
        await _wait(200);
        at = _textCenter(title);
      }
    }
    if (at == null) {
      emit(<String, Object?>{'error': 'no sidebar row for $title'});
      return;
    }
    await _tap(at);
    await _awaitChat(id);
  }

  Future<void> _switchChat(String id) async {
    if (_swipeMode) return _pagerSelect(id);
    final Element? e = _find((e) => e.widget is SidebarMobile);
    (e?.widget as SidebarMobile?)?.onChatSelected(id);
    await _awaitChat(id);
  }

  Future<void> _awaitChat(String id) async {
    final Stopwatch w = Stopwatch()..start();
    while (w.elapsedMilliseconds < 10000) {
      final ChukChatUIMobileState? c = _chat();
      if (c != null && c.widget.selectedChatId == id && c.transcriptRows.isNotEmpty) {
        break;
      }
      await _wait(4);
    }
    if (w.elapsedMilliseconds >= 10000) {
      final ChukChatUIMobileState? c = _chat();
      emit(<String, Object?>{
        'error': 'open timed out: wanted $id, '
            'has ${c?.widget.selectedChatId}, '
            'rows ${c?.transcriptRows.length}, '
            'sidebar ${c?.widget.isSidebarExpanded}, '
            'loading ${ChatStorageService.isLoadingChat}',
      });
    }
    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.endOfFrame;
  }

  Future<void> _sidebarOpen() async {
    final Size size =
        PlatformDispatcher.instance.views.first.physicalSize /
        PlatformDispatcher.instance.views.first.devicePixelRatio;
    await _drag(Offset(40, size.height * .45), const Offset(30, 0), 8);
    await _wait(320);
  }

  Future<void> _sidebarClose() async {
    final Size size =
        PlatformDispatcher.instance.views.first.physicalSize /
        PlatformDispatcher.instance.views.first.devicePixelRatio;
    await _drag(Offset(size.width - 40, size.height * .45), const Offset(-30, 0), 8);
    await _wait(320);
  }

  ScrollPosition get _chatScroll => _chat()!.scrollController.position;

  /// Waits until no frame is due, for [quietMs] in a row.
  Future<void> _settle({int quietMs = 200, int maxMs = 6000}) async {
    final Stopwatch w = Stopwatch()..start();
    final Stopwatch quiet = Stopwatch()..start();
    while (w.elapsedMilliseconds < maxMs &&
        quiet.elapsedMilliseconds < quietMs) {
      await _wait(8);
      if (SchedulerBinding.instance.hasScheduledFrame ||
          SchedulerBinding.instance.transientCallbackCount > 0) {
        quiet.reset();
      }
    }
  }

  Size get _logical {
    final FlutterView v = PlatformDispatcher.instance.views.first;
    return v.physicalSize / v.devicePixelRatio;
  }

  Future<void> _fling(Offset step) async {
    final Offset from = Offset(
      _logical.width / 2,
      step.dy > 0 ? _logical.height * .2 : _logical.height * .6,
    );
    await _drag(from, step, 12);
    await _settle();
  }

  /// All the ways through the long chat, then a stream under a moved reader.
  Future<void> _scrollPhases() async {
    Future<void> drag(double perFrame, int frames) => _drag(
      Offset(
        _logical.width / 2,
        perFrame > 0 ? _logical.height * .2 : _logical.height * .55,
      ),
      Offset(0, perFrame),
      frames,
    );

    await _phase('scroll up slow', () => drag(4, 200), note: '4 px per frame');
    await _phase('scroll down slow', () => drag(-4, 200), note: '4 px');
    await _phase('scroll up fast', () => drag(40, 200), note: '40 px per frame');
    await _phase('scroll down fast', () => drag(-40, 200), note: '40 px');
    await _phase(
      'fling up',
      () => _fling(const Offset(0, 80)),
      reps: 5,
      note: 'until it stops',
    );
    await _phase(
      'fling down',
      () => _fling(const Offset(0, -80)),
      reps: 5,
      note: 'until it stops',
    );
    await _phase('jumpTo top (no UI path)', () async {
      _chatScroll.jumpTo(_chatScroll.minScrollExtent);
      await _settle();
      _chatScroll.jumpTo(_chatScroll.minScrollExtent);
      await _settle();
    }, note: 'synthetic, like a scrollbar drag');
    await _phase('jump button from the top', () async {
      _chat()!.scrollChatToBottom(force: true);
      await _settle();
    }, note: 'the real button');
    _chatScroll.jumpTo(_chatScroll.pixels - 1500);
    await _settle();
    await _phase('jump button from 1500 px', () async {
      _chat()!.scrollChatToBottom(force: true);
      await _settle();
    }, note: 'animated');
  }

  Future<void> _awaitShell() async {
    final Stopwatch w = Stopwatch()..start();
    while (_chat() == null && w.elapsedMilliseconds < 30000) {
      await _wait(10);
    }
    emit(<String, Object?>{
      'cold': true,
      'shell_ms': DateTime.now().millisecondsSinceEpoch - mainAt,
      'main_at': mainAt,
      'found': _chat() != null,
    });
  }

  Future<void> coldOnly() => _awaitShell();

  /// One marker per phase; scripts/perf_census.py reads the timeline then.
  Future<void> _mark(String name) async {
    emit(<String, Object?>{'census': name});
    await _wait(5000);
  }

  Future<void> census() async {
    await _awaitShell();
    await _wait(20000); // the script attaches, startup work runs out
    await _mark('startup');
    for (int i = 0; i < 3; i++) {
      await _kbOpen();
      await _wait(500);
      await _kbClose();
      await _wait(500);
    }
    await _mark('keyboard x3, empty chat');
    await _openChat(kBenchLongTitle, kBenchLongChatId);
    await _wait(1500);
    await _mark('open long chat');
    if (_swipeMode) {
      for (int i = 0; i < 2; i++) {
        await _pagerSelect(kBenchShortChatId);
        await _wait(500);
        await _pagerSelect(kBenchLongChatId);
        await _wait(500);
      }
      await _mark('pager switch short and long x2');
      final double stripY = (MediaQueryData.fromView(
                PlatformDispatcher.instance.views.first,
              ).viewPadding.top +
              90) /
          _logical.height;
      for (int i = 0; i < 2; i++) {
        await _swipe(next: true, y: stripY);
        await _wait(400);
        await _swipe(next: false, y: stripY);
        await _wait(400);
      }
      await _mark('strip swipe next and back x2');
    }
    if (!_swipeMode) await _sidebarOpen();
    await _wait(500);
    final Offset? shortRow = _swipeMode ? null : _textCenter(kBenchShortTitle);
    emit(<String, Object?>{
      'error': 'probe: short row $shortRow, '
          'loading ${ChatStorageService.isLoadingChat}',
    });
    if (_swipeMode) {
      await _pagerSelect(kBenchShortChatId);
    } else if (shortRow != null) {
      await _tap(shortRow);
    }
    await _wait(2500);
    await _mark('open short chat');
    await _openChat(kBenchLongTitle, kBenchLongChatId);
    await _wait(1500);
    await _mark('reopen long chat');
    await _chat()!.resendMessageAt(_chat()!.transcriptRows.length - 1);
    await _settle();
    await _wait(1500);
    await _mark('retry last answer, long chat');
    for (int i = 0; i < 3; i++) {
      await _kbOpen();
      await _wait(500);
      await _kbClose();
      await _wait(500);
    }
    await _mark('keyboard x3, long chat');
    await _kbOpen();
    await _wait(1000);
    await _mark('keyboard settled');
    final EditableTextState e = _editable()!;
    String text = '';
    for (int i = 0; i < 10; i++) {
      text += 'a';
      e.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await _wait(200);
    }
    await _mark('typing x10, long chat');
    _chat()!.composerController.clear();
    await _kbClose();
    await _wait(500);
    await _mark('close');
    if (!_swipeMode) {
      await _sidebarOpen();
      await _wait(500);
      await _sidebarClose();
      await _mark('sidebar open and close');
    }
    await _mark('end');
    emit(<String, Object?>{'done': true});
  }

  /// The chat half: empty chat, long chat, sidebar, each from a clean state.
  Future<void> crawl() async {
    await _awaitShell();
    await _wait(6000);
    final Crawler c = Crawler(budget: const Duration(minutes: 28), emit: emit)
      ..start();
    benchShortStream = true;
    // The setup calls the app's own callbacks. A gesture here can land on a
    // selection handle or a menu that the last tap left open.
    Future<void> sidebar(bool open) async {
      final ChukChatUIMobileState? c = _chat();
      if (c == null || c.widget.isSidebarExpanded == open) return;
      c.widget.onToggleSidebar();
      await _wait(320);
    }

    Future<void> inChat(String title, String id) async {
      await sidebar(false);
      if (_chat()?.widget.selectedChatId == id) return;
      final Element? e = _find((e) => e.widget is SidebarMobile);
      (e?.widget as SidebarMobile?)?.onChatSelected(id);
      await _awaitChat(id);
      await _wait(600);
      if (_chat()?.widget.selectedChatId != id) {
        throw StateError('cannot reach $title');
      }
    }

    Future<void> root(
      String tag,
      Future<void> Function() setup,
      int minutes, {
      RegExp? skip,
    }) async {
      try {
        await c.crawlHere(
          0,
          setup: setup,
          tag: tag,
          rootBudget: Duration(minutes: minutes),
          skip: skip,
        );
      } on StateError catch (e) {
        emit(<String, Object?>{'crawl_skip': '$tag ended: ${e.message}'});
      }
    }

    // Navigation first, the chat rows of the sidebar last: their menus really
    // delete the synthetic chats.
    await root(
      'sidebar nav',
      () => sidebar(true),
      14,
      skip: RegExp(r'Sidebar chat|Bench (long|short) chat'),
    );
    await root('empty composer', () => sidebar(false), 2);
    await root('short chat', () => inChat(kBenchShortTitle, kBenchShortChatId), 3);
    await root('long chat', () => inChat(kBenchLongTitle, kBenchLongChatId), 4);
    await root('sidebar rows', () => sidebar(true), 2);
    await c.report();
    emit(<String, Object?>{'done': true});
  }

  Future<void> all() async {
    if (_census) return census();
    await _awaitShell();
    await _wait(12000); // deferred startup work runs out

    await _keyboardPhases('empty chat');
    await _typing('empty chat');

    await _phase(
      'open long chat, cache to frame',
      () => _openChat(kBenchLongTitle, kBenchLongChatId),
      reps: 1,
      note: '300 messages, sidebar tap to messages on screen',
    );
    await _wait(1500);
    await _keyboardPhases('long chat');
    await _typing('long chat');
    await _scrollPhases();
    _chat()!.scrollChatToBottom(animate: false, force: true);
    await _wait(1000);
    if (_swipeMode) {
      await _swipePhases();
    } else {
      await _phase('sidebar open, long chat', _sidebarOpen, reps: 5, between: _sidebarClose);
    }
    await _phase(
      'chat switch short then long',
      () async {
        await _switchChat(kBenchShortChatId);
        await _switchChat(kBenchLongChatId);
      },
      reps: 4,
      note: 'the sidebar row callback, twice',
    );
    await _wait(1000);
    await benchStreamPhase(_chat()!, _phase, _logical);
    emit(<String, Object?>{'done': true});
  }
}
