import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/cowork_thread_view.dart';

/// Builds the default production relay controller: a real [CoworkRelayClient]
/// with a freshly generated device signing key and id. Persisting that key
/// across launches is a later milestone; a fresh identity per session is fine
/// for a local run.
Future<CoworkRelayController> _defaultRelayControllerBuilder() async {
  final keyPair = await CoworkDeviceKeys.generate();
  return CoworkRelayClient(
    deviceId: const Uuid().v4(),
    signingKeyPair: keyPair,
  );
}

/// The CoWork surface: one full-width chat with the agent running on the
/// user's own host. Everything the account needs is in the conversation — no
/// side panels, no model lists. The login stays (the account token is provided
/// to the executor once paired), but nothing here fetches the account model
/// list.
class MessengerShell extends StatelessWidget {
  const MessengerShell({
    super.key,
    this.relayControllerBuilder,
    this.sessionSource = const SupabaseAccountSession(),
  });

  /// Builds the relay transport controller. Injectable so widget tests supply
  /// a fake without a socket. Defaults to a real [CoworkRelayClient].
  final Future<CoworkRelayController> Function()? relayControllerBuilder;

  /// Account session provisioned to the executor once paired.
  final AccountSessionSource sessionSource;

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
            relayControllerBuilder ?? _defaultRelayControllerBuilder,
        sessionSource: sessionSource,
      ),
    );
  }
}
