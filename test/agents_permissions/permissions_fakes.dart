import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart';

/// A stand-in for the host connection: what it sends, whether a host is
/// attached, and what the host said it can do.
class FakeHost {
  FakeHost({bool connected = true, bool supported = true})
    : connection = ValueNotifier<Object?>(connected ? Object() : null),
      capabilities = ValueNotifier<Set<String>>(
        supported ? const <String>{kAgentPermissionsCapability} : const {},
      );

  final ValueNotifier<Object?> connection;
  final ValueNotifier<Set<String>> capabilities;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  /// Makes every send throw, the way the relay does with no socket.
  bool fail = false;

  Future<void> send(Map<String, dynamic> payload) async {
    if (fail) throw StateError('Not connected to the host');
    sent.add(payload);
  }

  AgentsPermissionsService service() => AgentsPermissionsService(
    send: send,
    connection: connection,
    capabilities: capabilities,
  );

  void attach() => connection.value = Object();
  void detach() => connection.value = null;
  void nameCapability() =>
      capabilities.value = const <String>{kAgentPermissionsCapability};
}

Map<String, dynamic> permissionsReply(
  String agentId,
  AgentPermissions? p, {
  String? error,
  Map<String, bool>? enforced,
}) => <String, dynamic>{
  'type': 'agent_permissions',
  'agent_id': agentId,
  'permissions': ?p?.toJson(),
  'applies_from': 'next_task',
  'error': ?error,
  'enforced': ?enforced,
};
