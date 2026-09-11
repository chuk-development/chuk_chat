import 'package:flutter_test/flutter_test.dart';
import 'package:cowork/services/cowork/browser_presence.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import '../../support/fake_relay_controller.dart';

void main() {
  late FakeRelayController controller;
  late BrowserPresence presence;
  setUp(() {
    controller = FakeRelayController();
    controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
    presence = BrowserPresence(controller);
  });
  tearDown(() async {
    presence.dispose();
    await controller.dispose();
  });
  const available = CoworkRelayBrowserView(
    status: 'opened',
    vncAvailable: true,
  );
  test('fail closed without explicit VNC capability, including old hosts', () {
    expect(presence.value, isFalse);
    controller.emit(const CoworkRelayBrowserView(status: 'opened'));
    controller.emit(
      const CoworkRelayTool('browser_navigate', status: 'completed'),
    );
    controller.emit(
      const CoworkRelayRunState(
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
      const CoworkRelayBrowserView(status: 'opened', vncAvailable: false),
    );
    expect(presence.value, isFalse);
    controller.emit(available);
    controller.emit(const CoworkRelayBrowserView(status: 'closed'));
    expect(presence.value, isFalse);
  });
  test('a finished run leaves the screen there to take over', () {
    // Bead cowork-tf1u. The coworker ends its turn with "the browser is open,
    // you can take it over" — and that is the moment the user reaches for the
    // target. The run ending is not the browser closing.
    controller.emit(available);
    controller.emit(const CoworkRelayDone());
    expect(presence.value, isTrue);
    // An idle header that still advertises the browser keeps it.
    controller.emit(
      const CoworkRelayRunState(
        sessionKey: 't',
        state: 'idle',
        browserOpen: true,
        vncAvailable: true,
      ),
    );
    expect(presence.value, isTrue);
    controller.emit(const CoworkRelayDone(reason: 'replay'));
    expect(presence.value, isTrue);
  });

  test('the host closing the browser is what revokes the screen', () {
    controller.emit(available);
    expect(presence.value, isTrue);
    controller.emit(
      const CoworkRelayRunState(
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
      const CoworkRelayTool(
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
      controller.set(const CoworkRelayState(phase: CoworkRelayPhase.idle));
      expect(presence.value, isFalse);
      controller.emit(available);
      expect(presence.value, isFalse);
      controller.set(const CoworkRelayState(phase: CoworkRelayPhase.paired));
      expect(presence.value, isFalse);
      controller.emit(
        const CoworkRelayRunState(
          sessionKey: 't',
          state: 'running',
          browserOpen: true,
          vncAvailable: true,
        ),
      );
      expect(presence.value, isTrue);
    },
  );
  test('empty display and no-browser errors revoke capability', () {
    controller.emit(
      const CoworkRelayBrowserView(status: 'started', vncAvailable: true),
    );
    expect(presence.value, isTrue);
    controller.emit(
      const CoworkRelayBrowserView(
        status: 'started',
        vncAvailable: true,
        message: 'no page open yet',
      ),
    );
    expect(presence.value, isFalse);
    controller.emit(available);
    controller.emit(
      const CoworkRelayBrowserView(status: 'error', message: 'no browser open'),
    );
    expect(presence.value, isFalse);
  });
  test('only successful close tool revokes existing capability', () {
    controller.emit(
      const CoworkRelayTool('browser_navigate', status: 'started'),
    );
    expect(presence.value, isFalse);
    controller.emit(available);
    controller.emit(
      const CoworkRelayTool('browser_close', status: 'error', failed: true),
    );
    expect(presence.value, isTrue);
    controller.emit(
      const CoworkRelayTool(
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
        CoworkRelayRunState.fromPayload({
          'session_key': 't',
          'state': 'running',
          'browser_open': true,
          'vnc_available': capability,
        })!.vncAvailable,
        isFalse,
      );
    }
    expect(
      CoworkRelayRunState.fromPayload({
        'session_key': 't',
        'state': 'running',
        'browser_open': true,
        'vnc_available': true,
      })!.vncAvailable,
      isTrue,
    );
  });
}
