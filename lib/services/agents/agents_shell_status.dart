/// What the Agents shell says when there is no conversation to show.
///
/// A signed-in user with no computer, a computer that is still coming up, a
/// computer that is off, a connection with no agents yet: each of those used to
/// render as an empty chat area. The shell now resolves them to ONE status from
/// three inputs, and draws that status (`agents_status_panel.dart`):
///
///  * the thread view's view of the link ([AgentsLinkReport]),
///  * why the cloud restore last stopped ([AgentsPairingRestoreReason]),
///  * whether a parked host is being renewed right now (the heal channel).
///
/// The resolution is a pure function so every state is unit-testable without
/// a socket.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_pairing_restore.dart';

/// The link as the thread view sees it.
enum AgentsLinkState {
  /// The stored pairing has not been read yet.
  starting,

  /// This device holds no pairing.
  unpaired,

  /// Paired, and a connection is on its way (or the socket is between tries).
  connecting,

  /// Paired, and the computer did not answer after several tries, or the user
  /// disconnected on purpose.
  offline,

  /// Paired and connected.
  connected,
}

/// One snapshot of the link, published by the thread view for the shell.
@immutable
class AgentsLinkReport {
  const AgentsLinkReport(this.state, {this.busy = false, this.message});

  static const AgentsLinkReport initial = AgentsLinkReport(
    AgentsLinkState.starting,
  );

  final AgentsLinkState state;

  /// A connect or reconnect is in flight right now.
  final bool busy;

  /// A plain sentence about the last failure (never a URL, a code or an
  /// exception type), or null.
  final String? message;

  @override
  bool operator ==(Object other) =>
      other is AgentsLinkReport &&
      other.state == state &&
      other.busy == busy &&
      other.message == message;

  @override
  int get hashCode => Object.hash(state, busy, message);

  @override
  String toString() => 'AgentsLinkReport(${state.name}, busy: $busy)';
}

/// What the shell shows in place of a conversation.
enum AgentsShellStatus {
  /// The first frame or two: the stored pairing is being read.
  starting,

  /// No computer: the "Add your computer" call to action.
  notPaired,

  /// No computer on this device yet, but the account's computer may still be
  /// restored (the session, the key or the network is not ready yet).
  lookingForComputer,

  /// Paired, connecting.
  connecting,

  /// Paired, and a parked computer is being renewed.
  healing,

  /// Paired, and the computer does not answer.
  offline,

  /// Connected, and the computer has no agents yet.
  noAgents,

  /// Connected with agents: the shell shows the roster and the thread.
  ready,
}

/// Resolves the one status the shell shows.
AgentsShellStatus resolveAgentsShellStatus({
  required AgentsLinkReport link,
  required AgentsPairingRestoreReason restore,
  required bool healing,
  required bool rosterEmpty,
}) {
  switch (link.state) {
    case AgentsLinkState.starting:
      return AgentsShellStatus.starting;
    case AgentsLinkState.unpaired:
      // A pairing attempt that failed is the user's to retry: show the call to
      // action with the failure, not a search that is not happening.
      if (link.message != null) return AgentsShellStatus.notPaired;
      // The restore just wrote a pairing; the thread view is about to re-read
      // it and dial.
      if (restore == AgentsPairingRestoreReason.paired) {
        return AgentsShellStatus.connecting;
      }
      return restore.mayStillRestore
          ? AgentsShellStatus.lookingForComputer
          : AgentsShellStatus.notPaired;
    case AgentsLinkState.connecting:
      return healing ? AgentsShellStatus.healing : AgentsShellStatus.connecting;
    case AgentsLinkState.offline:
      return healing ? AgentsShellStatus.healing : AgentsShellStatus.offline;
    case AgentsLinkState.connected:
      return rosterEmpty ? AgentsShellStatus.noAgents : AgentsShellStatus.ready;
  }
}
