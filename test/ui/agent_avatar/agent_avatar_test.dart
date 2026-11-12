import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/ui/agent_avatar/agent_avatar.dart';
import 'package:chuk_chat/ui/agent_avatar/avatar_engine.dart';
import 'package:chuk_chat/ui/agent_avatar/avatar_rig.dart';
import 'package:chuk_chat/ui/agent_avatar/cube_figure.dart';

import '../../support/test_app.dart';

AgentsAgent _agent(String id, {bool running = false, DateTime? last}) =>
    AgentsAgent(
      id: id,
      name: id,
      threads: const [],
      running: running,
      lastActivity: last,
    );

dynamic _stateOf(WidgetTester tester, Finder f) => tester.state(f);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AgentAvatarFocus.instance.reset();
    agentAvatarMotion = false;
  });

  group('state from the agent', () {
    final DateTime now = DateTime(2026, 11, 12, 12);
    test('a running turn is work', () {
      expect(
        avatarStateOf(_agent('a', running: true), now),
        AgentAvatarState.work,
      );
    });
    test('long inactive is sleep, recent is idle', () {
      expect(
        avatarStateOf(
          _agent('a', last: now.subtract(const Duration(hours: 7))),
          now,
        ),
        AgentAvatarState.sleep,
      );
      expect(
        avatarStateOf(
          _agent('a', last: now.subtract(const Duration(minutes: 5))),
          now,
        ),
        AgentAvatarState.idle,
      );
      expect(avatarStateOf(_agent('a'), now), AgentAvatarState.idle);
    });

    testWidgets('a turn that just ended cheers, then goes idle', (
      tester,
    ) async {
      final AgentProfileStore store = AgentProfileStore();
      addTearDown(store.dispose);
      Widget at(bool running) => testApp(
        Center(
          child: AgentAvatar(
            agent: _agent('a', running: running),
            size: 64,
            store: store,
          ),
        ),
      );
      await tester.pumpWidget(at(true));
      await tester.pump();
      expect(
        _stateOf(tester, find.byType(AgentAvatar)).debugState,
        AgentAvatarState.work,
      );
      await tester.pumpWidget(at(false));
      await tester.pump();
      expect(
        _stateOf(tester, find.byType(AgentAvatar)).debugState,
        AgentAvatarState.done,
      );
    });
  });

  testWidgets('renders at every size from 24 to 96', (tester) async {
    final AgentProfileStore store = AgentProfileStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      testApp(
        Wrap(
          children: <Widget>[
            for (final double s in <double>[24, 32, 44, 48, 64, 96])
              AgentAvatar(
                agent: _agent('a', running: s > 40),
                size: s,
                store: store,
              ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final double s in <double>[24, 32, 44, 48, 64, 96]) {
      expect(
        find.byWidgetPredicate((Widget w) => w is AgentAvatar && w.size == s),
        findsOneWidget,
      );
    }
  });

  test('eye offsets clamp to the unit circle', () {
    expect(clampLook(const Offset(3, 4)).distance, closeTo(1, 1e-9));
    expect(clampLook(const Offset(0.3, 0.1)), const Offset(0.3, 0.1));
    final RigPose r = rigForPose(const AvatarPose(look: Offset(10, -10)));
    expect(r.pupil.distance, lessThanOrEqualTo(1 + 1e-9));
  });

  test('every pose stays inside the frame at every size', () {
    for (final double s in <double>[24, 32, 48, 64, 128]) {
      final Camera cam = cubeCamera(s);
      for (final RigPose r in fitPoses()) {
        r.jump *= kCubeJump;
        final Scene sc = Scene(cam);
        buildCube(sc, r, const Color(0xFF2962FF));
        final Rect b = sc.bounds()!;
        expect(b.left, greaterThanOrEqualTo(-0.01), reason: 'size $s');
        expect(b.top, greaterThanOrEqualTo(-0.01), reason: 'size $s');
        expect(b.right, lessThanOrEqualTo(s + 0.01), reason: 'size $s');
        expect(b.bottom, lessThanOrEqualTo(s + 0.01), reason: 'size $s');
      }
    }
  });

  test('a working avatar takes turns with every prop, whatever the agent', () {
    final Set<AvatarProp> seen = <AvatarProp>{
      for (double t = 0; t < kPropSeconds * kWorkProps.length; t += 1)
        propAt(t, 0),
    };
    expect(seen, kWorkProps.toSet());
    // The seed only shifts the order in time.
    expect(propAt(6, 0.5), isNot(propAt(6, 0)));
  });

  test('the body takes the agent colour hue', () async {
    const Color accent = Color(0xFF00BFA5);
    final ui.PictureRecorder rec = ui.PictureRecorder();
    paintCubeAvatar(Canvas(rec), 64, accent, const AvatarPose());
    final ui.Image img = await rec.endRecording().toImage(64, 64);
    final ByteData data = (await img.toByteData())!;
    final Color centre = Color.fromARGB(
      data.getUint8((40 * 64 + 32) * 4 + 3),
      data.getUint8((40 * 64 + 32) * 4),
      data.getUint8((40 * 64 + 32) * 4 + 1),
      data.getUint8((40 * 64 + 32) * 4 + 2),
    );
    expect(
      HSLColor.fromColor(centre).hue,
      closeTo(HSLColor.fromColor(accent).hue, 12),
    );
  });

  testWidgets('only the hovered agent follows the pointer, else the open one', (
    tester,
  ) async {
    final AgentProfileStore store = AgentProfileStore();
    addTearDown(store.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: <Widget>[
              for (final String id in <String>['a', 'b', 'c'])
                ListTile(
                  leading: AgentAvatar(
                    agent: _agent(id),
                    size: 48,
                    store: store,
                  ),
                  title: Text(id),
                ),
            ],
          ),
        ),
      ),
    );
    // The localisations load asynchronously; let them land.
    await tester.pumpAndSettle();
    AgentAvatarFocus.instance.openAgentId = 'c';
    expect(AgentAvatarFocus.instance.target, 'c');
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('a')));
    await tester.pump();
    expect(AgentAvatarFocus.instance.hoveredAgentId, 'a');
    expect(AgentAvatarFocus.instance.target, 'a');
    await mouse.moveTo(const Offset(5, 590));
    await tester.pump();
    expect(AgentAvatarFocus.instance.hoveredAgentId, isNull);
    expect(AgentAvatarFocus.instance.target, 'c');
  });

  testWidgets('a still idle avatar asks for no frames; a working one does', (
    tester,
  ) async {
    agentAvatarMotion = true;
    addTearDown(() => agentAvatarMotion = false);
    final AgentProfileStore store = AgentProfileStore();
    addTearDown(store.dispose);
    Widget at(bool running) => testApp(
      Center(
        child: AgentAvatar(
          agent: _agent('a', running: running),
          size: 64,
          store: store,
        ),
      ),
    );
    await tester.pumpWidget(at(false));
    await tester.pump(const Duration(seconds: 1));
    expect(_stateOf(tester, find.byType(AgentAvatar)).debugTicking, isFalse);
    await tester.pumpWidget(at(true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_stateOf(tester, find.byType(AgentAvatar)).debugTicking, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
