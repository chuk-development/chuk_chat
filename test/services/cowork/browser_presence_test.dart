import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/browser_presence.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';

import '../../support/fake_relay_controller.dart';

void main() {
  late FakeRelayController controller;
  late BrowserPresence presence;
  late List<bool> changes;

  setUp(() {
    controller = FakeRelayController();
    presence = BrowserPresence(controller);
    changes = <bool>[];
    presence.addListener(() => changes.add(presence.value));
  });

  tearDown(() async {
    presence.dispose();
    await controller.dispose();
  });

  test('starts closed', () {
    expect(presence.value, isFalse);
  });

  test('a completed Playwright tool means the browser is open', () {
    controller.emit(
      const CoworkRelayTool('mcp__playwright__browser_navigate',
          status: 'completed'),
    );
    expect(presence.value, isTrue);
    expect(changes, <bool>[true]);
  });

  test('browser_close means it is gone', () {
    controller.emit(
      const CoworkRelayTool('mcp__playwright__browser_snapshot',
          status: 'completed'),
    );
    controller.emit(
      const CoworkRelayTool('mcp__playwright__browser_close',
          status: 'completed'),
    );
    expect(presence.value, isFalse);
    expect(changes, <bool>[true, false]);
  });

  test('a failed browser tool proves nothing', () {
    controller.emit(
      const CoworkRelayTool('mcp__playwright__browser_navigate',
          status: 'error', failed: true),
    );
    expect(presence.value, isFalse);
    controller.emit(
      const CoworkRelayTool('mcp__playwright__browser_navigate',
          status: 'completed'),
    );
    controller.emit(
      const CoworkRelayTool('mcp__playwright__browser_close',
          status: 'error', failed: true),
    );
    expect(presence.value, isTrue, reason: 'a failed close leaves it open');
  });

  test('a deferred tool reached through tool_call counts by its inner name', () {
    controller.emit(
      const CoworkRelayTool(
        'tool_call',
        status: 'completed',
        argumentMap: <String, dynamic>{
          'name': 'mcp__playwright__browser_navigate',
          'arguments': <String, dynamic>{'url': 'https://example.com'},
        },
      ),
    );
    expect(presence.value, isTrue);
    controller.emit(
      const CoworkRelayTool(
        'tool_call',
        status: 'completed',
        argumentMap: <String, dynamic>{'name': 'mcp__playwright__browser_close'},
      ),
    );
    expect(presence.value, isFalse);
  });

  test('other tools are ignored, replayed frames count the same', () {
    controller.emit(const CoworkRelayTool('run_command', status: 'completed'));
    controller.emit(const CoworkRelayTool('web_fetch', status: 'completed'));
    expect(presence.value, isFalse);
    controller.emit(
      const CoworkRelayTool('mcp__playwright__browser_click',
          status: 'completed', replay: true, mid: 7),
    );
    expect(presence.value, isTrue);
  });

  test('the executor\'s browser_view verdicts refine the state', () {
    // A started stream with a window on the display: open.
    controller.emit(const CoworkRelayBrowserView(status: 'started'));
    expect(presence.value, isTrue);
    // A started stream with nothing on the display: closed.
    controller.emit(
      const CoworkRelayBrowserView(
        status: 'started',
        message: 'no page open yet — ask the agent to open a browser',
      ),
    );
    expect(presence.value, isFalse);
    controller.emit(const CoworkRelayBrowserView(status: 'started'));
    // Stream stopped: about the VNC view, not the browser — unchanged.
    controller.emit(const CoworkRelayBrowserView(status: 'stopped'));
    expect(presence.value, isTrue);
    // The executor could not even start x11vnc because no browser is open.
    controller.emit(
      const CoworkRelayBrowserView(
        status: 'error',
        message: 'no browser open yet — ask the agent to open a page first',
      ),
    );
    expect(presence.value, isFalse);
    // Any other error says nothing about the browser.
    controller.emit(const CoworkRelayBrowserView(status: 'started'));
    controller.emit(
      const CoworkRelayBrowserView(status: 'error', message: 'vnc bridge failed'),
    );
    expect(presence.value, isTrue);
  });

  test('a current host says it outright: opened/closed and run_state', () {
    controller.emit(const CoworkRelayBrowserView(status: 'opened'));
    expect(presence.value, isTrue);
    controller.emit(const CoworkRelayBrowserView(status: 'closed'));
    expect(presence.value, isFalse);
    controller.emit(
      const CoworkRelayRunState(
        sessionKey: 't', state: 'idle', browserOpen: true),
    );
    expect(presence.value, isTrue);
    // An old host's run_state (no field) leaves the derived state alone.
    controller.emit(const CoworkRelayRunState(sessionKey: 't', state: 'idle'));
    expect(presence.value, isTrue);
    controller.emit(
      const CoworkRelayRunState(
        sessionKey: 't', state: 'running', browserOpen: false),
    );
    expect(presence.value, isFalse);
  });

  test('reset forgets, dispose stops listening', () {
    controller.emit(
      const CoworkRelayTool('mcp__playwright__browser_navigate',
          status: 'completed'),
    );
    presence.reset();
    expect(presence.value, isFalse);
    presence.dispose();
    // Re-create so tearDown's dispose has something to dispose.
    presence = BrowserPresence(controller);
  });

  test('name helpers', () {
    expect(BrowserPresence.toolPart('mcp__playwright__browser_tab_new'),
        'browser_tab_new');
    expect(BrowserPresence.toolPart('browser_close'), 'browser_close');
    expect(BrowserPresence.isBrowserTool('mcp__playwright__browser_navigate'),
        isTrue);
    expect(BrowserPresence.isBrowserTool('mcp__other__browser_open'), isTrue);
    expect(BrowserPresence.isBrowserTool('mcp__other__fetch'), isFalse);
    expect(BrowserPresence.isBrowserTool('run_command'), isFalse);
  });
}
