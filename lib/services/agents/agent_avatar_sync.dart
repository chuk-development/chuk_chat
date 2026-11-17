/// Keeps the host's copy of each agent's avatar true
/// (docs/agents/NOTIFICATIONS.md, "Avatar on the host").
///
/// The host draws no avatar itself. The app sends one `agent_avatar_set`
/// frame per agent: when the agent is created, renamed or its photo changes,
/// and once per agent after a pairing (the host may have none yet). To make
/// "once" true across launches, the store remembers per host which picture
/// (fingerprint) of which agent it sent. A launch with nothing new sends
/// nothing.
///
/// The same run paints the notification PNGs of all agents, so the push
/// isolate finds a cached face even for an agent that never had a toast.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/notifications/notification_avatar.dart';

/// One agent as the sync needs it.
typedef AvatarAgent = ({String id, String name});

class AgentAvatarSync {
  AgentAvatarSync({AgentNotificationAvatar? avatars})
    : _avatars = avatars ?? AgentNotificationAvatar.instance;

  static final AgentAvatarSync instance = AgentAvatarSync();

  /// `{host device id: {agent id: fingerprint}}` as JSON.
  @visibleForTesting
  static const String prefsKey = 'cowork_agent_avatar_sent_v1';

  final AgentNotificationAvatar _avatars;

  /// Runs one after the other, so two triggers never send the same frame.
  Future<void> _chain = Future<void>.value();

  /// Paints the PNG of every agent in [agents] and, when [control] is set,
  /// sends each picture [hostId] has not got yet. Never throws.
  Future<void> sync({
    required Iterable<AvatarAgent> agents,
    AgentsAvatarControl? control,
    String? hostId,
  }) {
    final List<AvatarAgent> list = List<AvatarAgent>.of(agents);
    final Future<void> run = _chain.then(
      (_) => _run(list, control, hostId),
      onError: (Object _) => _run(list, control, hostId),
    );
    _chain = run.catchError((Object _) {});
    return _chain;
  }

  Future<void> _run(
    List<AvatarAgent> agents,
    AgentsAvatarControl? control,
    String? hostId,
  ) async {
    final bool send = control != null && hostId != null && hostId.isNotEmpty;
    final Map<String, Map<String, String>> sent = send
        ? await _loadSent()
        : <String, Map<String, String>>{};
    final Map<String, String> forHost = send
        ? (sent[hostId] ??= <String, String>{})
        : <String, String>{};
    bool changed = false;
    for (final AvatarAgent agent in agents) {
      try {
        final String? path = await _avatars.ensure(agent.id, name: agent.name);
        if (path == null || !send) continue;
        final String? fingerprint = await _avatars.cachedFingerprint(agent.id);
        if (fingerprint == null || forHost[agent.id] == fingerprint) continue;
        final Uint8List? bytes = await _avatars.pngBytes(
          agent.id,
          name: agent.name,
        );
        if (bytes == null ||
            bytes.isEmpty ||
            bytes.length > AgentNotificationAvatar.maxPngBytes) {
          continue;
        }
        // A link that never authenticates must not block later runs.
        await control
            .setAgentAvatar(agent.id, base64.encode(bytes))
            .timeout(const Duration(seconds: 60));
        forHost[agent.id] = fingerprint;
        changed = true;
      } catch (error) {
        // Not sent (link down): the next trigger tries again.
        if (kDebugMode) {
          debugPrint('[AgentAvatarSync] ${agent.id}: ${error.runtimeType}');
        }
      }
    }
    if (changed) await _saveSent(sent);
  }

  /// Forgets what was sent for [agentId] on every host (the agent was
  /// deleted), and its cached PNG.
  Future<void> forget(String agentId) async {
    await _avatars.forget(agentId);
    final Map<String, Map<String, String>> sent = await _loadSent();
    bool changed = false;
    for (final Map<String, String> forHost in sent.values) {
      if (forHost.remove(agentId) != null) changed = true;
    }
    if (changed) await _saveSent(sent);
  }

  static Future<Map<String, Map<String, String>>> _loadSent() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(prefsKey);
      if (raw == null || raw.isEmpty) return <String, Map<String, String>>{};
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, Map<String, String>>{};
      return <String, Map<String, String>>{
        for (final MapEntry<Object?, Object?> host in decoded.entries)
          if (host.value is Map)
            '${host.key}': <String, String>{
              for (final MapEntry<Object?, Object?> e
                  in (host.value as Map).entries)
                if (e.value is String) '${e.key}': e.value as String,
            },
      };
    } catch (_) {
      return <String, Map<String, String>>{};
    }
  }

  static Future<void> _saveSent(Map<String, Map<String, String>> sent) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(sent));
    } catch (_) {
      // The next launch sends again; the host overwrites the same file.
    }
  }
}
