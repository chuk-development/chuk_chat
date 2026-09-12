import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// How long the host's word on the browser stays good without fresh evidence.
///
/// The host never says "the browser is still there": `opened` / `closed` are
/// pushed once per CHANGE, and `run_state` rides on a replay. So a `true` that
/// nobody contradicts is not a fact, it is a memory — and the container, the
/// MCP server or Chromium itself can go away without a single frame saying so
/// (bead cowork-8ptj). After this long without a word, the screen target goes
/// back to parked: a dark target next to a live browser is a small annoyance,
/// a lit target next to no browser is the bug the user reported.
const Duration kBrowserPresenceFreshness = Duration(minutes: 5);

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
/// failed view, a header that no longer advertises the browser, the transport
/// going away, or [kBrowserPresenceFreshness] passing without a word.
/// VNC itself starts only when the user opens the viewer.
class BrowserPresence extends ValueNotifier<bool> {
  BrowserPresence(this.controller, {this.freshFor = kBrowserPresenceFreshness})
    : super(false) {
    final CoworkRelayState state = controller.state.value;
    _wasPaired = state.isPaired;
    _pairedWith = state.peerDeviceId;
    _sub = controller.inbound.listen(_onInbound);
    controller.state.addListener(_onConnectionChanged);
  }

  final CoworkRelayController controller;

  /// How long one word from the host stays good. Injected by tests.
  final Duration freshFor;

  StreamSubscription<CoworkRelayInbound>? _sub;
  Timer? _expiry;

  /// When the host last said the browser is there. Read at every [value], so a
  /// timer that fires late (a phone that slept through the deadline) cannot
  /// hand the user a lit target.
  DateTime? _saidAt;

  /// Why there is no screen on offer: a `browser_view` reason code, this app's
  /// own [staleReason], or empty when the host never said. Cleared by any
  /// fresh word.
  String _because = '';

  bool _wasPaired = false;
  String? _pairedWith;

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

  /// The host is opening the browser right now and the picture grows into the
  /// same stream (`started` + this reason). Not a verdict either way: an
  /// `opened` follows, so a lit target must not go dark on it.
  static const String openingReason = 'opening';

  /// The clock ran out on the host's last word — this app's own code, not the
  /// host's (see [kBrowserPresenceFreshness]).
  static const String staleReason = 'stale';

  /// What an executor `browser_view` frame says about the browser. `stopped`
  /// is about the VNC stream, not the browser, so it says nothing.
  ///
  /// `reason` is the machine-readable half of the frame (bead cowork-qp5i) and
  /// it decides. Reading the English text told "no browser open yet" apart
  /// from "could not start the VNC server" only for the one sentence somebody
  /// thought of, so every other failure left the target lit (bead cowork-8ptj).
  /// The text is now the fallback for a host too old to send a reason, and a
  /// code this app does not know closes the target like any other failure.
  static bool? stateFromView(CoworkRelayBrowserView view) {
    final String reason = view.reason;
    final String message = view.message.toLowerCase();
    switch (view.status) {
      case 'opened':
        return view.vncAvailable;
      case 'closed':
        return false;
      // Every failure to put the screen up closes it; the reason only says
      // which sentence the parked target gets.
      case 'error':
        return false;
      case 'started':
      case 'live':
        if (!view.vncAvailable) return false;
        if (reason.isEmpty) {
          // An old host: the sentence is all there is.
          return !message.contains('no page open');
        }
        // `opening` is the host working on it, and says nothing yet.
        return reason == openingReason ? null : false;
      default:
        return null;
    }
  }

  /// The host's word, and only while it is still fresh. A memory nobody has
  /// confirmed for [freshFor] is not an offer of a screen.
  @override
  bool get value => super.value && _isFresh;

  @override
  set value(bool next) => super.value = next;

  bool get _isFresh {
    final DateTime? said = _saidAt;
    if (said == null) return false;
    return DateTime.now().difference(said) < freshFor;
  }

  /// Why the target is parked, for the tap that asks. A `browser_view` reason
  /// code (`no_browser`, `no_sandbox`, `no_display`, `vnc_start_failed`,
  /// `exec_failed`, `bridge_failed`), this app's [staleReason] when the host
  /// fell silent on a screen it HAD offered, or empty when nobody ever said
  /// anything about a screen.
  String get parkedBecause => value ? '' : _because;

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
    if (next == false) {
      _revoke(because: event is CoworkRelayBrowserView ? event.reason : '');
      return;
    }
    if (next == true) {
      _keep(light: true);
      return;
    }
    // Nothing new about the capability, but a browser tool that just ran IS
    // proof the browser is alive. It may not light the target — a tool name
    // cannot tell a sandbox browser from the user's own — but it keeps a lit
    // one alive through a long session of browsing.
    if (super.value &&
        event is CoworkRelayTool &&
        stateFromTool(event) == true) {
      _keep(light: false);
    }
  }

  /// A fresh word from the host: restart the clock, and light the target when
  /// the word carried the capability.
  void _keep({required bool light}) {
    // What the listeners last saw, which is the MASKED value: a word that
    // arrives after the clock ran out revives a `true` the getter was already
    // hiding, and that flip has to reach the header like any other.
    final bool before = value;
    _saidAt = DateTime.now();
    _because = '';
    _expiry?.cancel();
    _expiry = Timer(freshFor, () => _revoke(because: staleReason));
    if (light && !super.value) {
      super.value = true;
    } else if (super.value && !before) {
      // The clock had run out on a `true` the getter was already hiding, and
      // this word put it back on the table — even a renewal has to say so.
      notifyListeners();
    }
  }

  void _revoke({String because = ''}) {
    _expiry?.cancel();
    _expiry = null;
    _saidAt = null;
    _because = because;
    if (super.value) super.value = false;
  }

  /// The transport changed. A screen is offered by ONE live pairing: a drop,
  /// and equally a fresh connection or a different peer, leaves the target
  /// parked until the new host says something of its own.
  void _onConnectionChanged() {
    final CoworkRelayState state = controller.state.value;
    final bool paired = state.isPaired;
    final bool sameSession =
        paired && _wasPaired && state.peerDeviceId == _pairedWith;
    _wasPaired = paired;
    _pairedWith = state.peerDeviceId;
    if (!sameSession) reset();
  }

  /// Forget the state (a new pairing, a different coworker).
  void reset() => _revoke();

  @override
  void dispose() {
    _expiry?.cancel();
    _expiry = null;
    controller.state.removeListener(_onConnectionChanged);
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
