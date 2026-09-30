/// What a coworker may do in its sandbox, as the host says
/// (docs/WIRE_CONTRACT.md, "Agent permissions").
///
/// The host is the truth. This service asks it for one coworker's permissions
/// (`agent_permissions_get`), sends a changed switch (`agent_permissions_set`
/// with only that key), and takes every `agent_permissions` reply as the whole
/// current set. A change applies from the coworker's next task, never in the
/// middle of one.
///
/// Everything is allowed by default. The one permission that starts off is the
/// user's own browser.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

/// How the workspace is bound into the sandbox.
enum AgentWorkspaceMount {
  /// The agent can change its files.
  rw,

  /// The agent can read its files and change none.
  ro,
}

/// One coworker's permissions. The defaults are the host's defaults.
@immutable
class AgentPermissions {
  const AgentPermissions({
    this.sudo = true,
    this.network = true,
    this.secretsEnv = true,
    this.workspaceMount = AgentWorkspaceMount.rw,
    this.userBrowser = false,
  });

  /// Everything on, except the user's own browser.
  static const AgentPermissions defaults = AgentPermissions();

  static const String keySudo = 'sudo';
  static const String keyNetwork = 'network';
  static const String keySecretsEnv = 'secrets_env';
  static const String keyWorkspaceMount = 'workspace_mount';
  static const String keyUserBrowser = 'user_browser';

  /// Every key, in the order the app shows them.
  static const List<String> keys = <String>[
    keySudo,
    keyNetwork,
    keySecretsEnv,
    keyWorkspaceMount,
    keyUserBrowser,
  ];

  /// Passwordless sudo in the sandbox.
  final bool sudo;

  /// The sandbox reaches the network.
  final bool network;

  /// The user's secrets reach the agent's commands as environment variables.
  final bool secretsEnv;

  /// Read-write or read-only workspace.
  final AgentWorkspaceMount workspaceMount;

  /// The agent drives the browser add-on on the user's computer.
  final bool userBrowser;

  bool get workspaceWritable => workspaceMount == AgentWorkspaceMount.rw;

  /// The switch state of [key]. The workspace switch is "writable".
  bool isOn(String key) => switch (key) {
    keySudo => sudo,
    keyNetwork => network,
    keySecretsEnv => secretsEnv,
    keyWorkspaceMount => workspaceWritable,
    keyUserBrowser => userBrowser,
    _ => throw ArgumentError.value(key, 'key', 'unknown permission'),
  };

  /// The wire value of one switch: a bool, or `rw` / `ro` for the workspace.
  static Object wireValue(String key, bool on) {
    if (!keys.contains(key)) {
      throw ArgumentError.value(key, 'key', 'unknown permission');
    }
    if (key == keyWorkspaceMount) return on ? 'rw' : 'ro';
    return on;
  }

  /// This set with one switch flipped to [on].
  AgentPermissions withSwitch(String key, bool on) => switch (key) {
    keySudo => copyWith(sudo: on),
    keyNetwork => copyWith(network: on),
    keySecretsEnv => copyWith(secretsEnv: on),
    keyWorkspaceMount => copyWith(
      workspaceMount: on ? AgentWorkspaceMount.rw : AgentWorkspaceMount.ro,
    ),
    keyUserBrowser => copyWith(userBrowser: on),
    _ => throw ArgumentError.value(key, 'key', 'unknown permission'),
  };

  AgentPermissions copyWith({
    bool? sudo,
    bool? network,
    bool? secretsEnv,
    AgentWorkspaceMount? workspaceMount,
    bool? userBrowser,
  }) {
    return AgentPermissions(
      sudo: sudo ?? this.sudo,
      network: network ?? this.network,
      secretsEnv: secretsEnv ?? this.secretsEnv,
      workspaceMount: workspaceMount ?? this.workspaceMount,
      userBrowser: userBrowser ?? this.userBrowser,
    );
  }

  /// Reads the host's `permissions` map. A key that is missing or has the
  /// wrong type keeps its default: the host always sends the whole set, so
  /// that only happens with a newer or broken host.
  factory AgentPermissions.fromJson(Map<String, dynamic> json) {
    bool flag(String key, bool fallback) {
      final Object? value = json[key];
      return value is bool ? value : fallback;
    }

    final Object? mount = json[keyWorkspaceMount];
    return AgentPermissions(
      sudo: flag(keySudo, defaults.sudo),
      network: flag(keyNetwork, defaults.network),
      secretsEnv: flag(keySecretsEnv, defaults.secretsEnv),
      workspaceMount: mount == 'ro'
          ? AgentWorkspaceMount.ro
          : AgentWorkspaceMount.rw,
      userBrowser: flag(keyUserBrowser, defaults.userBrowser),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    keySudo: sudo,
    keyNetwork: network,
    keySecretsEnv: secretsEnv,
    keyWorkspaceMount: workspaceMount.name,
    keyUserBrowser: userBrowser,
  };

  @override
  bool operator ==(Object other) =>
      other is AgentPermissions &&
      other.sudo == sudo &&
      other.network == network &&
      other.secretsEnv == secretsEnv &&
      other.workspaceMount == workspaceMount &&
      other.userBrowser == userBrowser;

  @override
  int get hashCode =>
      Object.hash(sudo, network, secretsEnv, workspaceMount, userBrowser);

  @override
  String toString() => 'AgentPermissions(${toJson()})';
}

/// Seals and sends one control frame to the host. Throws when nothing is
/// connected.
typedef AgentsControlFrameSender = Future<void> Function(
  Map<String, dynamic> payload,
);

Future<void> _sendOverRelay(Map<String, dynamic> payload) async {
  final Object? controller = AgentsRelayLink.instance.controller.value;
  if (controller is! AgentsRelayClient) {
    throw StateError('Not connected to the host');
  }
  await controller.sendControlFrame(payload);
}

/// The capability a host names in `host_route.capabilities` when it answers
/// the permission frames. The app sends them to no other host.
const String kAgentPermissionsCapability = 'agent_permissions';

/// The app's copy of the host's answers, per coworker.
///
/// It sends nothing to a host that did not name [kAgentPermissionsCapability]:
/// an older host answers an unknown frame with an `error`, and that is no
/// answer to show. It also notifies when the connection or the host's
/// capabilities change, so a section that found nobody to ask asks again as
/// soon as there is somebody.
class AgentsPermissionsService extends ChangeNotifier {
  AgentsPermissionsService({
    AgentsControlFrameSender? send,
    ValueListenable<Object?>? connection,
    ValueListenable<Set<String>>? capabilities,
  }) : _send = send ?? _sendOverRelay,
       _connection = connection ?? AgentsRelayLink.instance.controller,
       _capabilities = capabilities ?? AgentsRelayClient.hostCapabilities {
    _connection.addListener(notifyListeners);
    _capabilities.addListener(notifyListeners);
  }

  /// The one instance the app uses.
  static AgentsPermissionsService instance = AgentsPermissionsService();

  final AgentsControlFrameSender _send;
  final ValueListenable<Object?> _connection;
  final ValueListenable<Set<String>> _capabilities;
  final Map<String, AgentPermissions> _confirmed = <String, AgentPermissions>{};
  final Map<String, AgentPermissions> _optimistic =
      <String, AgentPermissions>{};
  final Map<String, Map<String, bool>> _enforced =
      <String, Map<String, bool>>{};
  final Map<String, String> _errors = <String, String>{};
  final Map<String, String> _appliesFrom = <String, String>{};

  /// Routes the relay's `agent_permissions` replies here. Idempotent.
  void attach() {
    AgentsRelayClient.agentPermissionsSink = handleFrame;
  }

  /// A host is connected right now.
  bool get connected => _connection.value != null;

  /// The connected host answers the permission frames.
  bool get supported =>
      _capabilities.value.contains(kAgentPermissionsCapability);

  /// True once the host answered for [agentId] with a set of permissions.
  /// Before that the switches show the defaults and stay disabled.
  bool isKnown(String agentId) => _confirmed.containsKey(agentId);

  /// What the section draws: the host's last answer, with a switch the user
  /// just flipped shown flipped until the host's reply lands.
  AgentPermissions permissionsOf(String agentId) =>
      _optimistic[agentId] ?? _confirmed[agentId] ?? AgentPermissions.defaults;

  /// The host's own answer only, or null before it answered.
  AgentPermissions? confirmedOf(String agentId) => _confirmed[agentId];

  /// Whether this host really enforces [key] for [agentId]. True until the
  /// host said otherwise (a host that sends no `enforced` enforces all).
  bool isEnforced(String agentId, String key) =>
      _enforced[agentId]?[key] ?? true;

  /// Why the host refused the last request, or null.
  String? errorOf(String agentId) => _errors[agentId];

  /// When a change takes effect, as the host said (`next_task`).
  String appliesFromOf(String agentId) => _appliesFrom[agentId] ?? 'next_task';

  /// Asks the host for [agentId]'s permissions. False when nothing is
  /// connected, the host does not answer these frames, or the frame could not
  /// be sent.
  Future<bool> refresh(String agentId) async {
    if (!supported) return false;
    try {
      await _send(<String, dynamic>{
        'type': 'agent_permissions_get',
        'agent_id': agentId,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Flips one switch. The row flips at once so it does not bounce; the
  /// host's reply (the truth) then replaces it, and puts it back when the host
  /// refused. False when the frame could not be sent; the switch is put back.
  Future<bool> setSwitch(String agentId, String key, bool on) async {
    final Object value = AgentPermissions.wireValue(key, on);
    if (!supported) return false;
    final AgentPermissions before = permissionsOf(agentId);
    _optimistic[agentId] = before.withSwitch(key, on);
    _errors.remove(agentId);
    notifyListeners();
    try {
      await _send(<String, dynamic>{
        'type': 'agent_permissions_set',
        'agent_id': agentId,
        'permissions': <String, dynamic>{key: value},
      });
      return true;
    } catch (_) {
      _optimistic.remove(agentId);
      notifyListeners();
      return false;
    }
  }

  /// Takes one `agent_permissions` reply for one coworker: the whole set, what
  /// this host enforces, and the reason when a request was refused. A reply
  /// with no set (an unknown coworker) carries only the reason. It may come
  /// from another device's change: the host sends every change to all of them.
  void handleFrame(Map<String, dynamic> payload) {
    if (payload['type'] != 'agent_permissions') return;
    final Object? agentId = payload['agent_id'];
    if (agentId is! String || agentId.isEmpty) return;
    final Object? permissions = payload['permissions'];
    final Object? error = payload['error'];
    final bool hasError = error is String && error.isNotEmpty;
    if (permissions is! Map && !hasError) return;
    if (permissions is Map) {
      _confirmed[agentId] = AgentPermissions.fromJson(
        permissions.map((Object? k, Object? v) => MapEntry('$k', v)),
      );
    }
    _optimistic.remove(agentId);
    if (hasError) {
      _errors[agentId] = error;
    } else {
      _errors.remove(agentId);
    }
    final Object? enforced = payload['enforced'];
    if (enforced is Map) {
      _enforced[agentId] = <String, bool>{
        for (final MapEntry<Object?, Object?> e in enforced.entries)
          if (e.value is bool) '${e.key}': e.value! as bool,
      };
    }
    final Object? appliesFrom = payload['applies_from'];
    if (appliesFrom is String && appliesFrom.isNotEmpty) {
      _appliesFrom[agentId] = appliesFrom;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _connection.removeListener(notifyListeners);
    _capabilities.removeListener(notifyListeners);
    super.dispose();
  }

  /// Test seam: forget every answer.
  @visibleForTesting
  void reset() {
    _confirmed.clear();
    _optimistic.clear();
    _enforced.clear();
    _errors.clear();
    _appliesFrom.clear();
  }
}
