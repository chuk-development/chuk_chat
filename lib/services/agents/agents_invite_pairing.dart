/// The pairing sequence for an invite, in one place.
///
/// Two ways lead here: the scanned or typed code (`AgentsPairingPage`) and the
/// install command (`AgentsInstallPage`). Both end in the same invite shape,
/// and both run exactly these steps:
///
///  1. connect over the relay and run the §15 ceremony as the joiner,
///  2. hand the executor the account token (ExecutorProvisioning); a failure
///     here does not undo the pairing (see below),
///  3. remember the trust in its RECONNECT form: the relay plus the host's
///     device id, which the relay's claim answer is the only source of.
///
/// The store write mirrors the trust, encrypted, to Supabase as it always did
/// (`AgentsPairingStore.savePairing`), so every other device of the account
/// restores it with no code.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// Runs the whole invite pairing on [controller] and returns the trust it
/// saved, or null when there was nothing to save (no [store], or a transport
/// that established no trust). Throws whatever the ceremony or the
/// provisioning throws; the caller turns that into one plain sentence.
Future<AgentsStoredPairing?> pairAgentsFromInvite({
  required AgentsRelayController controller,
  required AgentsPairingInvite invite,
  required AccountSessionSource sessionSource,
  AgentsPairingStore? store,
}) async {
  final address = AgentsCloudRelayAddress.forInvite(invite);
  await controller.connect(
    hostUrl: address.toUri(),
    pairingCode: invite.pairingCode,
  );
  // Paired: hand the executor the account token (ExecutorProvisioning).
  //
  // A provisioning failure does NOT undo the pairing. The ceremony is done
  // and the host has already kept its side of the trust. Without the token
  // it parks on its heal channel, and this app's reconnect claims that
  // channel and provisions again (AgentsCloudRelaySocket._healIfOffline,
  // then the reconnect's provisionAccount). Throwing the trust away here
  // would instead strand a host that only this app could heal.
  final session = sessionSource.current();
  if (session != null) {
    try {
      await controller.provisionAccount(session);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[agents-pairing] provisioning after pairing failed '
          '(${error.runtimeType}); the reconnect heals it',
        );
      }
    }
  }
  // The relay's own answer to the claim is the ONLY place the host's relay
  // device id comes from, so that is what the trust record remembers — not
  // the id the ceremony carried, which is the host's, not the relay's view
  // of it. Falls back to the ceremony's when the dial was local.
  final targetDeviceId =
      AgentsCloudRelaySocket.learnedTarget(
        base: invite.relayBase,
        pairingChannel: invite.pairingChannel,
      ) ??
      controller.establishedTrust?.peerDeviceId;
  return persistAgentsTrust(
    controller: controller,
    store: store,
    hostUrl: targetDeviceId == null
        ? null
        : AgentsCloudRelayAddress.forHost(
            base: invite.relayBase,
            targetDeviceId: targetDeviceId,
          ).toUri(),
  );
}

/// Saves the trust [controller] established, addressed at [hostUrl] when one
/// is given. Returns what was saved, or null when nothing was.
///
/// The address that gets remembered is the RECONNECT form: the relay plus the
/// host's device id. The pairing form carries the single-use pairing channel,
/// which must never be dialled twice and is worthless after the ceremony — a
/// trust record holding it would ask the relay to claim a channel that no
/// longer exists, on every launch, forever.
Future<AgentsStoredPairing?> persistAgentsTrust({
  required AgentsRelayController controller,
  required AgentsPairingStore? store,
  Uri? hostUrl,
}) async {
  final established = controller.establishedTrust;
  if (store == null || established == null) return null;
  final trust = hostUrl == null
      ? established
      : AgentsStoredPairing(
          hostUrl: hostUrl,
          channelId: established.channelId,
          channelKey: established.channelKey,
          peerDeviceId: established.peerDeviceId,
          peerPublicKey: established.peerPublicKey,
        );
  await store.savePairing(trust);
  return trust;
}
