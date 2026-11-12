/// `AgentAvatar`: an agent's face, everywhere it appears (inbox rows,
/// pinned row, chat header, right panel, switcher, profile).
///
/// The face is the cube figure in `cube_figure.dart`, in the agent's colour
/// ([agentAccent], the same colour as its bubbles). A picture the user set
/// for the agent ([AgentProfileStore]) still wins.
///
/// States come from what the app observes about the agent:
///  * work  — a turn is running ([AgentsAgent.running]);
///  * done  — a turn has just ended (one cheer, [kCheerSeconds]);
///  * sleep — nothing happened for [kAgentSleepAfter];
///  * idle  — otherwise.
///
/// Only one agent follows the pointer: the one whose row the pointer is
/// over, else the open agent ([AgentAvatarFocus.openAgentId]). Every other
/// avatar looks straight ahead.
///
/// Cost: each pose is drawn once into an offscreen image at device pixels
/// and then only blitted. The ticker runs only while something moves (work, cheer, a state
/// blend, a blink, the followed agent settling on the pointer) and stops
/// after, so a still list asks for no frames. A sleeping avatar redraws its
/// Zzz five times a second on a timer. At [kAvatarStillBelow] or less only
/// the blink moves. Each avatar sits in its own [RepaintBoundary]; tickers
/// obey [TickerMode]; avatars in lazy lists are built only when visible.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/ui/agent_avatar/avatar_rig.dart';
import 'package:chuk_chat/ui/agent_avatar/cube_figure.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart' show agentAccent;
import 'package:chuk_chat/ui/expressive/face_image.dart';
import 'package:chuk_chat/utils/io_helper.dart' show Platform;

export 'package:chuk_chat/ui/agent_avatar/avatar_rig.dart'
    show AgentAvatarState;

/// The figure painter: the round figure ("D1 rund"). The square cube
/// ([paintCubeAvatar]) is the other style; swap it here.
typedef AgentAvatarPainter = void Function(
  Canvas canvas,
  double size,
  Color accent,
  AvatarPose pose, {
  bool dark,
});

const AgentAvatarPainter kAgentAvatarPainter = paintRoundAvatar;

/// No activity for this long and the avatar sleeps.
const Duration kAgentSleepAfter = Duration(hours: 6);

/// Whether avatars move at all. Off under `flutter test`, so a running
/// agent's endless work loop cannot keep `pumpAndSettle` from settling;
/// tests of the motion itself switch it on.
bool agentAvatarMotion = Platform.environment['FLUTTER_TEST'] != 'true';

/// At this size or less the avatar holds still; only the eyes blink.
const double kAvatarStillBelow = 32;

/// The state the app's observations give an agent at [now] (no cheer; the
/// cheer is the moment a running turn stops, seen by the widget).
AgentAvatarState avatarStateOf(AgentsAgent agent, DateTime now) {
  if (agent.running) return AgentAvatarState.work;
  final DateTime? last = agent.lastActivity;
  if (last != null && now.difference(last) > kAgentSleepAfter) {
    return AgentAvatarState.sleep;
  }
  return AgentAvatarState.idle;
}

final Stopwatch _clock = Stopwatch()..start();
double get _now => _clock.elapsedMicroseconds / 1e6;

/// Which agent follows the pointer, and where the pointer is. One instance
/// for the app; avatars read it, nothing rebuilds when it changes.
class AgentAvatarFocus {
  AgentAvatarFocus._();
  static final AgentAvatarFocus instance = AgentAvatarFocus._();

  final Set<_AgentAvatarState> _live = <_AgentAvatarState>{};
  bool _routed = false;

  /// The pointer in global coordinates, null before it ever moved.
  Offset? pointer;
  double _pointerAt = -10;

  String? _hovered;
  String? _open;

  /// The agent whose row the pointer is over.
  String? get hoveredAgentId => _hovered;

  /// The agent open in the chat pane; set by the shell.
  String? get openAgentId => _open;
  set openAgentId(String? id) {
    if (id == _open) return;
    final String? before = target;
    _open = id;
    _retarget(before);
  }

  /// The one agent that follows the pointer.
  String? get target => _hovered ?? _open;

  void _retarget(String? before) {
    final String? now = target;
    if (now == before) return;
    for (final _AgentAvatarState s in _live) {
      if (s._id == before || s._id == now) s._wake();
    }
  }

  void _add(_AgentAvatarState s) {
    _live.add(s);
    if (!_routed) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      _routed = true;
    }
  }

  void _remove(_AgentAvatarState s) {
    _live.remove(s);
    if (_live.isEmpty && _routed) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      _routed = false;
      if (_hovered != null) _hovered = null;
    }
  }

  void _onPointer(PointerEvent e) {
    if (e is! PointerHoverEvent && e is! PointerMoveEvent) return;
    pointer = e.position;
    _pointerAt = _now;
    String? over;
    for (final _AgentAvatarState s in _live) {
      final Rect? r = s._rowRect();
      if (r != null && r.contains(e.position)) {
        over = s._id;
        break;
      }
    }
    if (over != _hovered) {
      final String? before = target;
      _hovered = over;
      _retarget(before);
    }
    final String? t = target;
    if (t == null) return;
    for (final _AgentAvatarState s in _live) {
      if (s._id == t) s._wake();
    }
  }

  /// How many avatars are mounted; for tests and the perf harness.
  @visibleForTesting
  int get debugLiveCount => _live.length;

  /// How many avatars are ticking right now; for the perf harness.
  @visibleForTesting
  int get debugTickingCount => _live.where((s) => s._ticker.isActive).length;

  /// Forgets everything; for tests.
  @visibleForTesting
  void reset() {
    _hovered = null;
    _open = null;
    pointer = null;
  }
}

class AgentAvatar extends StatefulWidget {
  const AgentAvatar({
    super.key,
    required AgentsAgent this.agent,
    this.size = 56,
    this.state,
    this.showPresence = true,
    this.store,
    this.dimmed = false,
    this.profileOverride,
  }) : id = null,
       label = null;

  /// A face for an identity known only by id and label (a room member, a
  /// picker row). Same figure and colour, no presence, no state.
  const AgentAvatar.id({
    super.key,
    required String this.id,
    required String this.label,
    this.size = 32,
    this.store,
    this.dimmed = false,
  }) : agent = null,
       state = AgentAvatarState.idle,
       showPresence = false,
       profileOverride = null;

  final AgentsAgent? agent;
  final String? id;
  final String? label;
  final double size;

  /// Forces a state; null derives it from [agent].
  final AgentAvatarState? state;
  final bool showPresence;

  /// Injectable for tests; defaults to the app-wide store.
  final AgentProfileStore? store;

  /// A hidden agent is shown faded.
  final bool dimmed;

  /// An unsaved editor preview; app surfaces always read the store.
  final AgentProfile? profileOverride;

  String get agentId => agent?.id ?? id ?? '';

  /// The presence dot colour: green while a run is in flight, amber when a
  /// schedule is armed, none while it waits.
  static Color? presenceColor(AgentActivity activity) => switch (activity) {
    AgentActivity.working => const Color(0xFF34C759),
    AgentActivity.scheduled => const Color(0xFFFF9F0A),
    AgentActivity.waiting => null,
  };

  @override
  State<AgentAvatar> createState() => _AgentAvatarState();
}

class _AgentAvatarState extends State<AgentAvatar>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _Frame _frame = _Frame();
  late final math.Random _rng = math.Random(widget.agentId.hashCode);
  late final double _seed = _rng.nextDouble();

  Offset _look = Offset.zero;
  Offset _vel = Offset.zero;
  double _last = _now;

  AgentAvatarState _state = AgentAvatarState.idle;
  AgentAvatarState _prev = AgentAvatarState.idle;
  double _stateStart = -10;
  double _prevT = 10;
  double _doneUntil = -1;

  double _blinkStart = -1;
  double _paintedAt = -1;
  Timer? _blinkTimer;
  Timer? _sleepTimer;

  bool _reduce = false;
  bool _dark = false;
  Element? _row;

  String get _id => widget.agentId;

  /// The state shown now; for tests.
  @visibleForTesting
  AgentAvatarState get debugState => _state;

  /// Whether the ticker runs; for tests.
  @visibleForTesting
  bool get debugTicking => _ticker.isActive;
  bool get _still => widget.size <= kAvatarStillBelow;

  @override
  void initState() {
    super.initState();
    _state = _derive();
    _prev = _state;
    AgentAvatarFocus.instance._add(this);
    _paint();
    _scheduleBlink();
    // The ticker reads TickerMode from the tree, so start motion after the
    // first frame, not from initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void didUpdateWidget(AgentAvatar old) {
    super.didUpdateWidget(old);
    if (old.agent?.running == true && widget.agent?.running == false) {
      _doneUntil = _now + kCheerSeconds;
    }
    _row = null;
    _sync();
  }

  @override
  void dispose() {
    AgentAvatarFocus.instance._remove(this);
    _blinkTimer?.cancel();
    _sleepTimer?.cancel();
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  AgentAvatarState _derive() {
    final AgentAvatarState? forced = widget.state;
    if (forced != null) return forced;
    final AgentsAgent? a = widget.agent;
    if (a == null) return AgentAvatarState.idle;
    if (!a.running && _now < _doneUntil) return AgentAvatarState.done;
    return avatarStateOf(a, DateTime.now());
  }

  /// Applies a state change and starts whatever motion it needs.
  void _sync() {
    final AgentAvatarState s = _derive();
    if (s != _state) {
      _prev = _state;
      _prevT = _now - _stateStart;
      _state = s;
      _stateStart = _now;
    }
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (_state == AgentAvatarState.sleep && !_reduce && !_still) {
      _sleepTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _paint(),
      );
    }
    _wake();
  }

  void _scheduleBlink() {
    _blinkTimer?.cancel();
    if (!agentAvatarMotion) return;
    final bool working = _state == AgentAvatarState.work;
    final double wait = working
        ? 0.8 + _rng.nextDouble() * 1.4
        : 2.4 + _rng.nextDouble() * 4;
    _blinkTimer = Timer(Duration(milliseconds: (wait * 1000).round()), () {
      if (!mounted) return;
      if (_state != AgentAvatarState.sleep && !_reduce) {
        _blinkStart = _now;
        _wake();
      }
      _scheduleBlink();
    });
  }

  bool get _following =>
      AgentAvatarFocus.instance.target == _id &&
      AgentAvatarFocus.instance.pointer != null;

  /// Starts the ticker if something is to move.
  void _wake() {
    if (!mounted) return;
    if (!_ticker.isActive && _wantsFrames()) {
      _last = _now;
      _ticker.start();
    } else if (!_ticker.isActive) {
      _paint();
    }
  }

  bool _wantsFrames() {
    if (_blinkStart >= 0) return true;
    if (_reduce) return false;
    if (_now - _stateStart < 0.5) return true;
    if (_still) return false;
    if (_state == AgentAvatarState.work || _state == AgentAvatarState.done) {
      return true;
    }
    if (_following && _now - AgentAvatarFocus.instance._pointerAt < 0.3) {
      return true;
    }
    // Settling back to (or onto) the target.
    return (_look - _targetLook()).distance > 0.003 || _vel.distance > 0.003;
  }

  /// The row this avatar sits in: the nearest ink-bearing ancestor (a list
  /// tile or an InkWell), else the avatar itself.
  Rect? _rowRect() {
    if (!mounted) return null;
    _row ??= _findRow();
    final RenderObject? ro = (_row ?? context as Element).renderObject;
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
    return ro.localToGlobal(Offset.zero) & ro.size;
  }

  Element? _findRow() {
    Element? found;
    int depth = 0;
    (context as Element).visitAncestorElements((Element e) {
      final Widget w = e.widget;
      if (w is ListTile || w is InkWell || w is InkResponse) {
        found = e;
        return false;
      }
      return ++depth < 40;
    });
    return found;
  }

  Offset _targetLook() {
    if (!_following || _state == AgentAvatarState.sleep || _still) {
      return Offset.zero;
    }
    final RenderObject? ro = context.findRenderObject();
    final Offset? p = AgentAvatarFocus.instance.pointer;
    if (p == null || ro is! RenderBox || !ro.hasSize || !ro.attached) {
      return Offset.zero;
    }
    final Offset d = p - ro.localToGlobal(ro.size.center(Offset.zero));
    final double dist = d.distance;
    if (dist < 1) return Offset.zero;
    return d / dist * (dist / (widget.size * 1.5 + 60)).clamp(0.0, 1.0);
  }

  void _tick(Duration _) {
    final double now = _now;
    final double dt = (now - _last).clamp(0.0, 0.05);
    _last = now;
    if (_state == AgentAvatarState.done &&
        now >= _doneUntil &&
        widget.state == null) {
      _sync();
    }
    // Spring toward the look target (stiffness 140, a little under-damped).
    const double k = 140, c = 2 * 0.78 * 11.83;
    final Offset target = _targetLook();
    if (_reduce) {
      _look = target;
      _vel = Offset.zero;
    } else {
      _vel += ((target - _look) * k - _vel * c) * dt;
      _look = clampLook(_look + _vel * dt);
    }
    if (_blinkStart >= 0 && now - _blinkStart > 0.16) _blinkStart = -1;
    // Loops of avatars that do not follow the pointer draw at 30 fps.
    final bool smooth =
        _following || _blinkStart >= 0 || now - _stateStart < 0.5;
    if (smooth || now - _paintedAt >= 1 / 30) {
      _paintedAt = now;
      _paint();
    }
    if (!_wantsFrames()) _ticker.stop();
  }

  void _paint() {
    final double now = _now;
    final double blink = _state == AgentAvatarState.sleep
        ? 1
        : (_blinkStart >= 0
              ? math.sin(((now - _blinkStart) / 0.16).clamp(0.0, 1.0) * math.pi)
              : 0);
    final bool frozen = _reduce || _still;
    _frame.pose = AvatarPose(
      look: _look,
      blink: blink,
      t: frozen ? 0 : now + _seed * 50,
      state: _state,
      stateT: frozen ? 10 : now - _stateStart,
      prev: _prev,
      prevT: _prevT,
      seed: _seed,
    );
    _frame.dark = _dark;
    _frame.tick();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduce =
        !agentAvatarMotion ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    if (reduce != _reduce || dark != _dark) {
      _reduce = reduce;
      _dark = dark;
      _paint();
    }
    final AgentProfileStore profiles =
        widget.store ?? AgentProfileStore.instance;
    return AnimatedBuilder(
      animation: profiles,
      builder: (BuildContext context, Widget? _) => _build(context, profiles),
    );
  }

  Widget _build(BuildContext context, AgentProfileStore profiles) {
    final double size = widget.size;
    final AgentProfile profile =
        widget.profileOverride ?? profiles.profileOf(_id);
    final Color accent = widget.profileOverride?.colorValue != null
        ? Color(widget.profileOverride?.colorValue ?? 0)
        : agentAccent(context, _id, store: profiles);
    final ImageProvider<Object>? photo = faceImageProvider(profile.photoPath);
    final Widget face = photo != null
        ? Container(
            width: size,
            height: size,
            decoration: ShapeDecoration(
              shape: const CircleBorder(),
              image: DecorationImage(image: photo, fit: BoxFit.cover),
            ),
          )
        : RepaintBoundary(
            child: CustomPaint(
              size: Size.square(size),
              painter: _AvatarPainter(
                frame: _frame,
                accent: accent,
                dpr: MediaQuery.devicePixelRatioOf(context),
              ),
            ),
          );
    final AgentsAgent? agent = widget.agent;
    final Color? dot = widget.showPresence && agent != null
        ? AgentAvatar.presenceColor(agent.activity)
        : null;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.label ?? agent?.name,
      image: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Opacity(
          opacity: widget.dimmed ? 0.4 : 1.0,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              face,
              if (dot != null)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Semantics(
                    label: agent?.activity == AgentActivity.working
                        ? 'working'
                        : 'scheduled',
                    child: Container(
                      width: (size * 0.30).clamp(9.0, 18.0),
                      height: (size * 0.30).clamp(9.0, 18.0),
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surface, width: 2.5),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The latest pose plus the rendered picture of it. The picture is drawn
/// once per pose change, offscreen at device resolution, and then only
/// blitted, so a still avatar costs one image draw per frame.
class _Frame extends ChangeNotifier {
  AvatarPose pose = const AvatarPose();
  bool dark = false;
  int version = 0;

  ui.Image? image;
  int imageVersion = -1;
  double imageDpr = 0;
  double imageSize = 0;
  Color? imageAccent;

  void tick() {
    version++;
    notifyListeners();
  }

  @override
  void dispose() {
    image?.dispose();
    image = null;
    super.dispose();
  }
}

/// Paints the figure into an image, offscreen, at device pixels, and draws
/// that image 1:1.
///
/// Why offscreen: Impeller smooths path edges only through MSAA. Its
/// on-screen GL surface on Linux has one sample per pixel
/// (`impeller/renderer/backend/gles/surface_gles.cc`, `SampleCount::kCount1`),
/// so the faces drawn straight onto the screen came out jagged; offscreen
/// targets get 4x MSAA (`capabilities_gles.cc`). It also means Impeller,
/// which has no raster cache, does not re-raster an unchanged avatar every
/// frame: it only draws the image again.
class _AvatarPainter extends CustomPainter {
  _AvatarPainter({required this.frame, required this.accent, required this.dpr})
    : super(repaint: frame);

  final _Frame frame;
  final Color accent;
  final double dpr;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.shortestSide;
    final int px = (s * dpr).ceil();
    if (px <= 0) return;
    ui.Image? image = frame.image;
    if (image == null ||
        frame.imageVersion != frame.version ||
        frame.imageDpr != dpr ||
        frame.imageSize != s ||
        frame.imageAccent != accent) {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final Canvas c = Canvas(rec);
      c.scale(dpr);
      kAgentAvatarPainter(c, s, accent, frame.pose, dark: frame.dark);
      final ui.Picture picture = rec.endRecording();
      final ui.Image next = picture.toImageSync(px, px);
      picture.dispose();
      frame.image?.dispose();
      frame.image = next;
      image = next;
      frame.imageVersion = frame.version;
      frame.imageDpr = dpr;
      frame.imageSize = s;
      frame.imageAccent = accent;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()),
      Rect.fromLTWH(0, 0, px / dpr, px / dpr),
      Paint()
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_AvatarPainter old) =>
      old.accent != accent || old.frame != frame || old.dpr != dpr;
}
