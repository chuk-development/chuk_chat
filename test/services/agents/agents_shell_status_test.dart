import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_pairing_restore.dart';
import 'package:chuk_chat/services/agents/agents_shell_status.dart';

void main() {
  AgentsShellStatus resolve(
    AgentsLinkState link, {
    AgentsPairingRestoreReason restore = AgentsPairingRestoreReason.checking,
    bool healing = false,
    bool rosterEmpty = true,
    String? message,
  }) => resolveAgentsShellStatus(
    link: AgentsLinkReport(link, message: message),
    restore: restore,
    healing: healing,
    rosterEmpty: rosterEmpty,
  );

  test('before the pairing is read the shell is starting', () {
    expect(resolve(AgentsLinkState.starting), AgentsShellStatus.starting);
  });

  test('unpaired: looking while a restore can land, add once it cannot', () {
    for (final AgentsPairingRestoreReason reason
        in AgentsPairingRestoreReason.values) {
      final AgentsShellStatus status = resolve(
        AgentsLinkState.unpaired,
        restore: reason,
      );
      final AgentsShellStatus expected =
          reason == AgentsPairingRestoreReason.paired
          ? AgentsShellStatus.connecting
          : reason.mayStillRestore
          ? AgentsShellStatus.lookingForComputer
          : AgentsShellStatus.notPaired;
      expect(status, expected, reason: reason.name);
    }
  });

  test('a failed pairing attempt shows the call to action, not a search', () {
    expect(
      resolve(
        AgentsLinkState.unpaired,
        restore: AgentsPairingRestoreReason.network,
        message: 'Pairing did not work.',
      ),
      AgentsShellStatus.notPaired,
    );
  });

  test('paired: connecting, offline, and the heal line over both', () {
    expect(resolve(AgentsLinkState.connecting), AgentsShellStatus.connecting);
    expect(resolve(AgentsLinkState.offline), AgentsShellStatus.offline);
    expect(
      resolve(AgentsLinkState.connecting, healing: true),
      AgentsShellStatus.healing,
    );
    expect(
      resolve(AgentsLinkState.offline, healing: true),
      AgentsShellStatus.healing,
    );
  });

  test('connected: no agents, or ready', () {
    expect(resolve(AgentsLinkState.connected), AgentsShellStatus.noAgents);
    expect(
      resolve(AgentsLinkState.connected, rosterEmpty: false),
      AgentsShellStatus.ready,
    );
  });

  test('a heal never hides a missing computer', () {
    expect(
      resolve(
        AgentsLinkState.unpaired,
        restore: AgentsPairingRestoreReason.noCloudRecord,
        healing: true,
      ),
      AgentsShellStatus.notPaired,
    );
  });
}
