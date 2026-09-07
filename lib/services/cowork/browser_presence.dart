import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// Whether the current live run is using the agent's browser.
///
/// The agent's browser is the Playwright MCP server inside its sandbox
/// (`cowork-browser-mcp`): Chromium comes up on the first `browser_*` tool and
/// goes away on `browser_close`. Every one of those calls reaches the app as a
/// `tool` frame (docs/WIRE_CONTRACT.md, "Tool events and timestamps") — so
/// the app can follow live browser use without polling:
///
/// * a live `mcp__playwright__browser_<x>` tool (or a `tool_call` wrapper
///   naming one) means a page is open;
/// * a completed `browser_close` means it is gone;
/// * the executor's own `browser_view` verdicts refine that: `started` with an
///   empty message = a window is on the display, `started` with the "no page
///   open yet" message or the "no browser open yet" error = nothing to show;
/// * a current host says it outright: `browser_view` `opened` / `closed`
///   pushed on every change, and `browser_open` in every `run_state` (the
///   replay header), which wins over anything derived here.
///
/// Historical tools never make the browser available. A reconnect uses the
/// current run-state header, and a live run ending hides the entry point even
/// when Chromium remains open in the sandbox. Opening the viewer stays an
/// explicit user action, so a tool call cannot interrupt reading the chat.
class BrowserPresence extends ValueNotifier<bool> {
  BrowserPresence(this.controller) : super(false) {
    _sub = controller.inbound.listen(_onInbound);
  }

  final CoworkRelayController controller;
  StreamSubscription<CoworkRelayInbound>? _sub;
  bool _runEnded = false;

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
    if (tool.replay ||
        tool.failed ||
        tool.status == 'error' ||
        tool.status == 'failed') {
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
        return true;
      case 'closed':
        return false;
      case 'started':
      case 'live':
        return !message.contains('no page open');
      case 'error':
        if (message.contains('no browser open')) return false;
        return null;
      default:
        return null;
    }
  }

  void _onInbound(CoworkRelayInbound event) {
    if (event is CoworkRelayRunState) {
      _runEnded = event.state != 'running';
    } else if (event is CoworkRelayDone && !event.isReplay) {
      _runEnded = true;
    } else if (event is CoworkRelayTool && stateFromTool(event) == true) {
      _runEnded = false;
    }
    final bool? next = switch (event) {
      CoworkRelayTool() => stateFromTool(event),
      CoworkRelayBrowserView() => _runEnded ? false : stateFromView(event),
      // The host's word in the replay header (a current host; null on an old
      // one, which leaves the derived state alone).
      CoworkRelayRunState() =>
        event.state == 'running' ? event.browserOpen : false,
      CoworkRelayDone() => event.isReplay ? null : false,
      _ => null,
    };
    if (next != null && next != value) value = next;
  }

  /// Forget the state (a new pairing, a different coworker).
  void reset() {
    _runEnded = false;
    if (value) value = false;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
