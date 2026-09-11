import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// Whether the host explicitly offers a viewable sandbox browser.
///
/// An active relay and `vnc_available: true` on a live browser-view event or a
/// replay header are required. Browser tool names are insufficient: the user's
/// extension browser uses those same names but has no VNC display. Missing
/// capability (including old hosts) fails closed.
///
/// The state follows the BROWSER, not the run (bead cowork-tf1u). A coworker
/// that finishes its turn leaves its Chromium open and says so — "the browser
/// is open, you can take it over" — and that is exactly the moment the user
/// reaches for the screen target. Treating the run's `done` as "the screen is
/// gone" made the target die one second after the coworker offered it. Only
/// the host revokes: a completed `browser_close`, a `browser_view: closed`, a
/// header that no longer advertises the browser, or the transport going away.
/// VNC itself starts only when the user opens the viewer.
class BrowserPresence extends ValueNotifier<bool> {
  BrowserPresence(this.controller) : super(false) {
    _sub = controller.inbound.listen(_onInbound);
    controller.state.addListener(_onConnectionChanged);
  }

  final CoworkRelayController controller;
  StreamSubscription<CoworkRelayInbound>? _sub;

  /// The tool-name prefix the agent's MCP client gives the Playwright server
  /// (`mcp__<server>__<tool>`, `cowork_agent.mcp_client.tool_name`).
  static const String playwrightPrefix = 'mcp__playwright__';

  /// The deferred-tool wrapper: an MCP tool the model reached through
  /// `tool_call(name=..., arguments=...)` shows up under this name, with the
  /// real tool in `arguments.name`.
  static const String toolCallWrapper = 'tool_call';

  /// The Playwright tool that closes the browser.
  static const String closeTool = 'browser_close';

  /// The tool part of an MCP tool name: `mcp__playwright__browser_navigate`
  /// → `browser_navigate`; a bare name is returned as it is.
  static String toolPart(String name) {
    final int idx = name.lastIndexOf('__');
    return idx < 0 ? name : name.substring(idx + 2);
  }

  /// The effective tool name of a tool frame: the wrapped name for a
  /// `tool_call`, else the frame's own name.
  static String effectiveName(CoworkRelayTool tool) {
    if (tool.name == toolCallWrapper) {
      final Object? inner = tool.argumentMap?['name'];
      if (inner is String && inner.isNotEmpty) return inner;
    }
    return tool.name;
  }

  /// True for a Playwright MCP browser tool: the `mcp__playwright__` prefix,
  /// or a tool part that starts with `browser_` (the server's naming scheme).
  static bool isBrowserTool(String name) {
    if (name.startsWith(playwrightPrefix)) return true;
    return toolPart(name).startsWith('browser_');
  }

  /// What a tool frame says about the browser: true = open, false = closed,
  /// null = nothing (not a browser tool, or a failed call that proves nothing).
  static bool? stateFromTool(CoworkRelayTool tool) {
    final String name = effectiveName(tool);
    if (!isBrowserTool(name)) return null;
    if (tool.replay || tool.failed || tool.status != 'completed') {
      return null;
    }
    return toolPart(name) != closeTool;
  }

  /// What an executor `browser_view` frame says about the browser. `stopped`
  /// is about the VNC stream, not the browser, so it says nothing.
  static bool? stateFromView(CoworkRelayBrowserView view) {
    final String message = view.message.toLowerCase();
    switch (view.status) {
      case 'opened':
        return view.vncAvailable;
      case 'closed':
        return false;
      case 'started':
      case 'live':
        return view.vncAvailable && !message.contains('no page open');
      case 'error':
        if (message.contains('no browser open')) return false;
        return null;
      default:
        return null;
    }
  }

  void _onInbound(CoworkRelayInbound event) {
    // A retained socket/controller is not evidence of a reachable screen.
    // Reconnection must obtain fresh presence from the host's replay header.
    if (!controller.state.value.isPaired) return;
    final bool? next = switch (event) {
      // Tool names cannot distinguish a sandbox browser from user_browser.
      // Only the host's explicit capability may enable the viewer, so a tool
      // frame may close the screen but never open it.
      CoworkRelayTool() => stateFromTool(event) == false ? false : null,
      CoworkRelayBrowserView() => stateFromView(event),
      // The header is the host's standing word on the browser, whether or not
      // a run happens to be in flight. Old hosts, which advertise neither
      // field, fail closed.
      CoworkRelayRunState() => event.browserOpen == true && event.vncAvailable,
      // A finished run says nothing about the browser: the coworker leaves the
      // page open on purpose, so the user can take it over (bead cowork-tf1u).
      CoworkRelayDone() => null,
      _ => null,
    };
    if (next != null && next != value) value = next;
  }

  void _onConnectionChanged() {
    if (!controller.state.value.isPaired) reset();
  }

  /// Forget the state (a new pairing, a different coworker).
  void reset() {
    if (value) value = false;
  }

  @override
  void dispose() {
    controller.state.removeListener(_onConnectionChanged);
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
