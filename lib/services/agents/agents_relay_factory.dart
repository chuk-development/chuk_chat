// lib/services/agents/agents_relay_factory.dart
//
// The production relay controller, built in one place: by the Agents shell
// for its thread view, and by [AgentsBackgroundLink] when queued prompts must
// go out while no thread view holds a link.
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_mail_key_handover.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/herenow/herenow_store.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';
import 'package:chuk_chat/services/secrets/secrets_service.dart';
import 'package:chuk_chat/services/session_recovery.dart';

/// Builds the default production relay controller: a real [AgentsRelayClient]
/// with the app's **stable** long-term device identity, loaded from (or created
/// in) [store] on first use. A stable key is what lets the host's stored trust
/// keep matching us across restarts, so the reconnect handshake authenticates
/// with no code.
Future<AgentsRelayController> buildDefaultAgentsRelayController(
  AgentsPairingStore store,
  AccountSessionSource sessionSource,
) async {
  // A session recovery holds the device's one relay socket while it runs (the
  // link dials the same relay with the same device id). The gate mounts the
  // shell immediately so the reader sees their conversation from disk, but the
  // transport waits its turn — two sockets for one device would displace the
  // recovery and lose the very session it was fetching back.
  final Future<void>? recovery = SessionRecovery.inFlight;
  if (recovery != null) {
    try {
      await recovery;
    } catch (_) {
      // A failed recovery is not this builder's problem; the gate decides
      // whether the user stays in the shell at all.
    }
  }
  final identity = await store.loadOrCreateIdentity();
  return AgentsRelayClient(
    deviceId: identity.deviceId,
    signingKeyPair: identity.keyPair,
    onTrustUpdated: store.savePairing,
    // The pipe. A `wss://…/v2/relay/ws` address goes through the cloud relay
    // (authenticated as this account's controller, frames wrapped as opaque
    // `cowork_relay` payloads); a plain `ws://127.0.0.1:8787` still opens the
    // local blind relay exactly as before, for same-machine development.
    connector: agentsCloudRelayConnector(
      deviceId: identity.deviceId,
      sessionSource: sessionSource,
    ),
    // The user's UI-configured MCP servers ride along on each task frame,
    // resolved with their live bearers at launch (WS-D).
    mcpStore: McpStore(),
    // The here.now publishing connector setting rides along the same way, so a
    // public publish is gated on the user's yes (or their auto-approve opt-in).
    hereNowStore: HereNowStore(),
    // The user's secret set follows every provision (docs/WIRE_CONTRACT.md,
    // "Secrets"), so a restarted host holds what the device holds.
    secretsForwarder: SecretsService.instance.forwardToHost,
    // So does the mail key (docs/AGENT_MAIL.md §6.1): the host opens the
    // user's sealed mail with it.
    mailKeyForwarder: AgentMailKeyHandover.instance.forwardTo,
  );
}
