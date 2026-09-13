import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/agents/browser_presence.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import '../../support/fake_relay_controller.dart';

void main() {
  late FakeRelayController controller;
  late BrowserPresence presence;
  setUp(() {
    controller = FakeRelayController();
    controller.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
    presence = BrowserPresence(controller);
  });
  tearDown(() async {
    presence.dispose();
    await controller.dispose();
  });
  const available = AgentsRelayBrowserView(
    status: 'opened',
    vncAvailable: true,
  );
  test('fail closed without explicit VNC capability, including old hosts', () {
    expect(presence.value, isFalse);
    controller.emit(const AgentsRelayBrowserView(status: 'opened'));
    controller.emit(
      const AgentsRelayTool('browser_navigate', status: 'completed'),
    );
    controller.emit(
      const AgentsRelayRunState(
        sessionKey: 't',
        state: 'running',
        browserOpen: true,
      ),
    );
    expect(presence.value, isFalse);
  });
  test('sandbox capability opens, user browser and closed state do not', () {
    controller.emit(available);
    expect(presence.value, isTrue);
    controller.emit(
      const AgentsRelayBrowserView(status: 'opened', vncAvailable: false),
    );
    expect(presence.value, isFalse);
    controller.emit(available);
    controller.emit(const AgentsRelayBrowserView(status: 'closed'));
    expect(presence.value, isFalse);
  });
  test('a finished run leaves the screen there to take over', () {
    // Bead cowork-tf1u. The coworker ends its turn with "the browser is open,
    // you can take it over" — and that is the moment the user reaches for the
    // target. The run ending is not the browser closing.
    controller.emit(available);
    controller.emit(const AgentsRelayDone());
    expect(presence.value, isTrue);
    // An idle header that still advertises the browser keeps it.
    controller.emit(
      const AgentsRelayRunState(
        sessionKey: 't',
        state: 'idle',
        browserOpen: true,
        vncAvailable: true,
      ),
    );
    expect(presence.value, isTrue);
    controller.emit(const AgentsRelayDone(reason: 'replay'));
    expect(presence.value, isTrue);
  });

  test('the host closing the browser is what revokes the screen', () {
    controller.emit(available);
    expect(presence.value, isTrue);
    controller.emit(
      const AgentsRelayRunState(
        sessionKey: 't',
        state: 'idle',
        browserOpen: false,
        vncAvailable: false,
      ),
    );
    expect(presence.value, isFalse);
  });

  test('a replayed browser tool cannot open the screen', () {
    controller.emit(
      const AgentsRelayTool(
        'browser_navigate',
        status: 'completed',
        replay: true,
      ),
    );
    expect(presence.value, isFalse);
  });
  test(
    'disconnect clears presence and reconnect needs fresh host evidence',
    () {
      controller.emit(available);
      expect(presence.value, isTrue);
      controller.set(const AgentsRelayState(phase: AgentsRelayPhase.idle));
      expect(presence.value, isFalse);
      controller.emit(available);
      expect(presence.value, isFalse);
      controller.set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
      expect(presence.value, isFalse);
      controller.emit(
        const AgentsRelayRunState(
          sessionKey: 't',
          state: 'running',
          browserOpen: true,
          vncAvailable: true,
        ),
      );
      expect(presence.value, isTrue);
    },
  );
  test('every failure to put the screen up parks the target, and says why', () {
    // Beads cowork-8ptj / cowork-qp5i. The old rule read the English sentence
    // and only believed "no browser open"; every other failure — the VNC
    // server that would not start, the bridge that died, a sandbox that is not
    // there — left the target lit, and the user found out by tapping it. The
    // reason code decides now, and the tap gets it.
    const List<String> codes = <String>[
      'no_sandbox',
      'no_display',
      'vnc_start_failed',
      'exec_failed',
      'bridge_failed',
      // A code this app has never heard of closes it like any other failure.
      'something_new',
    ];
    for (final String code in codes) {
      controller.emit(available);
      expect(presence.value, isTrue, reason: 'lit before $code');
      controller.emit(
        AgentsRelayBrowserView(
          status: 'error',
          message: 'whatever the host writes here',
          reason: code,
        ),
      );
      expect(presence.value, isFalse, reason: 'still lit after $code');
      expect(presence.parkedBecause, code);
    }
    // An old host sends no reason at all. Its failures close it too.
    controller.emit(available);
    controller.emit(
      const AgentsRelayBrowserView(
        status: 'error',
        message: 'could not start the VNC server',
      ),
    );
    expect(presence.value, isFalse);
    expect(presence.parkedBecause, isEmpty);
  });
  test('a live stream reports the display through its reason', () {
    // `started` with nothing to explain means a page IS on the display.
    controller.emit(
      const AgentsRelayBrowserView(status: 'started', vncAvailable: true),
    );
    expect(presence.value, isTrue);
    // An empty display with nothing that can open a page takes it away.
    controller.emit(
      const AgentsRelayBrowserView(
        status: 'started',
        vncAvailable: true,
        message: 'nothing here',
        reason: 'no_browser',
      ),
    );
    expect(presence.value, isFalse);
    expect(presence.parkedBecause, 'no_browser');
  });
  test('the host opening the page is not the host having no page', () {
    // `opening`: the display is empty because the browser is coming up right
    // now, and the picture grows into this same stream. A lit target must not
    // go dark on it, and a dark one waits for the `opened` that follows.
    const AgentsRelayBrowserView opening = AgentsRelayBrowserView(
      status: 'started',
      vncAvailable: true,
      message: 'opening the browser',
      reason: BrowserPresence.openingReason,
    );
    controller.emit(opening);
    expect(presence.value, isFalse);
    controller.emit(available);
    expect(presence.value, isTrue);
    controller.emit(opening);
    expect(presence.value, isTrue);
  });
  test('a fresh connection never inherits the last one\'s screen', () {
    // The transport can go from paired to paired: a re-pair, or the same app
    // attaching to a different coworker. A screen belongs to ONE live
    // pairing, so the new host has to say so itself.
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'host-a',
      ),
    );
    controller.emit(available);
    expect(presence.value, isTrue);
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'host-b',
      ),
    );
    expect(presence.value, isFalse);
    controller.emit(available);
    expect(presence.value, isTrue);
    // The same pairing carrying on (a detail line changes) keeps the screen.
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'host-b',
        detail: 'Reconnected',
      ),
    );
    expect(presence.value, isTrue);
  });
  test('the host\'s word goes stale on its own', () async {
    // Nothing on the wire says "the browser is STILL there": opened/closed are
    // pushed once per change. So a container that dies, an MCP server that is
    // restarted or a Chromium that crashes leaves a `true` standing forever —
    // the reported bug. The word expires instead.
    final BrowserPresence short = BrowserPresence(
      controller,
      freshFor: const Duration(milliseconds: 30),
    );
    addTearDown(short.dispose);
    int lits = 0;
    short.addListener(() => lits++);
    controller.emit(available);
    expect(short.value, isTrue);
    expect(short.parkedBecause, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(short.value, isFalse);
    // The tap can now say WHY it went dark, instead of "no screen yet".
    expect(short.parkedBecause, BrowserPresence.staleReason);
    expect(lits, 2);
    // And a fresh word brings it back, listeners included.
    controller.emit(available);
    expect(short.value, isTrue);
    expect(short.parkedBecause, isEmpty);
    expect(lits, 3);
  });
  test('live browser work keeps a lit target alive', () async {
    // The renewal may not LIGHT the target — a tool name cannot tell a sandbox
    // browser from the user's own extension browser — but a completed
    // Playwright call is proof the browser is alive, so it holds the screen
    // through a long session of browsing.
    final BrowserPresence short = BrowserPresence(
      controller,
      freshFor: const Duration(milliseconds: 100),
    );
    addTearDown(short.dispose);
    controller.emit(available);
    for (int i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.emit(
        const AgentsRelayTool(
          'mcp__playwright__browser_navigate',
          status: 'completed',
        ),
      );
      expect(short.value, isTrue, reason: 'tool $i');
    }
    // A tool alone still cannot open a screen the host never offered.
    final BrowserPresence dark = BrowserPresence(
      controller,
      freshFor: const Duration(milliseconds: 100),
    );
    addTearDown(dark.dispose);
    controller.emit(
      const AgentsRelayTool(
        'mcp__playwright__browser_navigate',
        status: 'completed',
      ),
    );
    expect(dark.value, isFalse);
    // Silence ends it all the same.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(short.value, isFalse);
  });
  test('empty display and no-browser errors revoke capability', () {
    controller.emit(
      const AgentsRelayBrowserView(status: 'started', vncAvailable: true),
    );
    expect(presence.value, isTrue);
    controller.emit(
      const AgentsRelayBrowserView(
        status: 'started',
        vncAvailable: true,
        message: 'no page open yet',
      ),
    );
    expect(presence.value, isFalse);
    controller.emit(available);
    controller.emit(
      const AgentsRelayBrowserView(status: 'error', message: 'no browser open'),
    );
    expect(presence.value, isFalse);
  });
  test('only successful close tool revokes existing capability', () {
    controller.emit(
      const AgentsRelayTool('browser_navigate', status: 'started'),
    );
    expect(presence.value, isFalse);
    controller.emit(available);
    controller.emit(
      const AgentsRelayTool('browser_close', status: 'error', failed: true),
    );
    expect(presence.value, isTrue);
    controller.emit(
      const AgentsRelayTool(
        'tool_call',
        status: 'completed',
        argumentMap: {'name': 'mcp__playwright__browser_close'},
      ),
    );
    expect(presence.value, isFalse);
  });
  test('run-state decoder requires literal boolean true', () {
    for (final capability in [null, false, 'true', 1]) {
      expect(
        AgentsRelayRunState.fromPayload({
          'session_key': 't',
          'state': 'running',
          'browser_open': true,
          'vnc_available': capability,
        })!.vncAvailable,
        isFalse,
      );
    }
    expect(
      AgentsRelayRunState.fromPayload({
        'session_key': 't',
        'state': 'running',
        'browser_open': true,
        'vnc_available': true,
      })!.vncAvailable,
      isTrue,
    );
  });
}
