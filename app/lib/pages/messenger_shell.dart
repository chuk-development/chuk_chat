import 'package:flutter/material.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

/// Builds the default production relay controller: a real [CoworkRelayClient]
/// with the app's **stable** long-term device identity, loaded from (or created
/// in) [store] on first use. A stable key is what lets the host's stored trust
/// keep matching us across restarts, so the reconnect handshake authenticates
/// with no code.
Future<CoworkRelayController> _buildRelayController(
  CoworkPairingStore store,
) async {
  final identity = await store.loadOrCreateIdentity();
  return CoworkRelayClient(
    deviceId: identity.deviceId,
    signingKeyPair: identity.keyPair,
  );
}

/// The CoWork surface: one full-width chat with the agent running on the
/// user's own host. Everything the account needs is in the conversation — no
/// side panels, no model lists. The login stays (the account token is provided
/// to the executor once paired), but nothing here fetches the account model
/// list.
class MessengerShell extends StatelessWidget {
  MessengerShell({
    super.key,
    this.relayControllerBuilder,
    this.sessionSource = const SupabaseAccountSession(),
    CoworkPairingStore? pairingStore,
  }) : pairingStore = pairingStore ?? CoworkPairingStore();

  /// Builds the relay transport controller. Injectable so widget tests supply
  /// a fake without a socket. Defaults to a real [CoworkRelayClient] with the
  /// stable persisted identity.
  final Future<CoworkRelayController> Function()? relayControllerBuilder;

  /// Account session provisioned to the executor once paired.
  final AccountSessionSource sessionSource;

  /// Persistent trust store: the stable device identity and the stored pairing
  /// that drives code-free reconnect.
  final CoworkPairingStore pairingStore;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CoWork'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => const AuthService().signOut(),
          ),
        ],
      ),
      body: CoworkThreadView(
        controllerBuilder:
            relayControllerBuilder ?? () => _buildRelayController(pairingStore),
        sessionSource: sessionSource,
        pairingStore: pairingStore,
      ),
    );
  }
}
