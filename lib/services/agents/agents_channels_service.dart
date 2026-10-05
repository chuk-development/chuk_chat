/// A coworker's messenger channels, as the host says (bead chuk_chat-02s5).
///
/// Today there is one channel, Telegram. The host runs it: it keeps the bot
/// token, polls Telegram, and pairs one chat with a 6-digit code. This service
/// asks the host for one coworker's channel (`agent_channel_get`), sends what
/// the user does (`agent_channel_set` with an action), and takes every
/// `agent_channel` frame — an answer or an unprompted push — as the whole
/// current state. The token goes to the host once and never comes back; the
/// host only says `has_token`.
///
/// The frames go only to a host that names [kAgentChannelsCapability] in
/// `host_route.capabilities`. An older host would answer an unknown frame with
/// an `error`, and that is no state to show.
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart'
    show AgentsControlFrameSender;
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

/// The capability a host names when it answers the channel frames.
const String kAgentChannelsCapability = 'agent_channels';

/// The one channel kind there is.
const String kTelegramChannel = 'telegram';

/// What the user can ask the host to do with a channel.
enum AgentChannelAction {
  /// Turn it on. Carries the bot token the first time.
  enable,

  /// Turn it off. The token and the link stay.
  disable,

  /// Turn it off and drop the token and the link.
  forget,

  /// Drop the linked Telegram chat. The bot stays on.
  unlink,

  /// Link the chat that got the 6-digit code. Carries the code.
  link,
}

/// One coworker's Telegram channel, as the host last said.
@immutable
class AgentChannelState {
  const AgentChannelState({
    this.enabled = false,
    this.allowed = true,
    this.hasToken = false,
    this.state = 'off',
    this.botUsername = '',
    this.linked = false,
    this.linkedName = '',
    this.pendingLink = false,
    this.pendingLinkExpiresAt,
  });

  /// The user turned it on.
  final bool enabled;

  /// The host's owner allows Telegram at all.
  final bool allowed;

  /// The host keeps a bot token for this coworker.
  final bool hasToken;

  /// `off`, `disallowed`, `starting`, `polling`, `backoff`, `conflict`,
  /// `unauthorized` or `stopped`.
  final String state;

  /// The bot's name without the `@`, or empty before the host asked Telegram.
  final String botUsername;

  /// One Telegram chat is linked.
  final bool linked;

  /// The linked chat's name, or empty.
  final String linkedName;

  /// The bot sent a code and waits for it.
  final bool pendingLink;

  /// When that code stops working, or null.
  final DateTime? pendingLinkExpiresAt;

  /// Reads one `agent_channel` frame. A missing or mistyped field keeps its
  /// default.
  factory AgentChannelState.fromJson(Map<String, dynamic> json) {
    bool flag(String key, bool fallback) {
      final Object? value = json[key];
      return value is bool ? value : fallback;
    }

    String text(String key, String fallback) {
      final Object? value = json[key];
      return value is String ? value : fallback;
    }

    final Object? expires = json['pending_link_expires_at'];
    return AgentChannelState(
      enabled: flag('enabled', false),
      allowed: flag('allowed', true),
      hasToken: flag('has_token', false),
      state: text('state', 'off'),
      botUsername: text('bot_username', '').replaceFirst(RegExp(r'^@'), ''),
      linked: flag('linked', false),
      linkedName: text('linked_name', ''),
      pendingLink: flag('pending_link', false),
      pendingLinkExpiresAt: expires is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (expires * 1000).round(),
              isUtc: true,
            )
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentChannelState &&
      other.enabled == enabled &&
      other.allowed == allowed &&
      other.hasToken == hasToken &&
      other.state == state &&
      other.botUsername == botUsername &&
      other.linked == linked &&
      other.linkedName == linkedName &&
      other.pendingLink == pendingLink &&
      other.pendingLinkExpiresAt == pendingLinkExpiresAt;

  @override
  int get hashCode => Object.hash(
    enabled,
    allowed,
    hasToken,
    state,
    botUsername,
    linked,
    linkedName,
    pendingLink,
    pendingLinkExpiresAt,
  );
}

Future<void> _sendOverRelay(Map<String, dynamic> payload) async {
  final Object? controller = AgentsRelayLink.instance.controller.value;
  if (controller is! AgentsRelayClient) {
    throw StateError('Not connected to the host');
  }
  await controller.sendControlFrame(payload);
}

/// The app's copy of the host's channel answers, per coworker.
class AgentsChannelsService extends ChangeNotifier {
  AgentsChannelsService({
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
  static AgentsChannelsService instance = AgentsChannelsService();

  final AgentsControlFrameSender _send;
  final ValueListenable<Object?> _connection;
  final ValueListenable<Set<String>> _capabilities;
  final Map<String, AgentChannelState> _states = <String, AgentChannelState>{};
  final Map<String, String> _errors = <String, String>{};
  final Set<String> _busy = <String>{};

  /// Routes the relay's `agent_channel` frames here. Idempotent.
  void attach() {
    AgentsRelayClient.agentChannelSink = handleFrame;
  }

  /// A host is connected right now.
  bool get connected => _connection.value != null;

  /// The connected host runs channels.
  bool get supported => _capabilities.value.contains(kAgentChannelsCapability);

  /// The host's last state for [agentId]'s Telegram channel, or null before
  /// it answered.
  AgentChannelState? stateOf(String agentId) => _states[agentId];

  /// The error code of the last answer, or null when it had none.
  String? errorOf(String agentId) => _errors[agentId];

  /// A request went out and its answer has not come back.
  bool isBusy(String agentId) => _busy.contains(agentId);

  /// Gives up on the answer to the last request: the host did not reply.
  void cancelBusy(String agentId) {
    if (_busy.remove(agentId)) notifyListeners();
  }

  /// Asks the host for [agentId]'s Telegram channel. False when the host does
  /// not run channels or the frame could not be sent.
  Future<bool> refresh(String agentId) async {
    if (!supported) return false;
    try {
      await _send(<String, dynamic>{
        'type': 'agent_channel_get',
        'agent_id': agentId,
        'channel': kTelegramChannel,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends one [action]. [token] goes with `enable`, [code] with `link`; empty
  /// values are left off. False when the frame could not be sent.
  Future<bool> act(
    String agentId,
    AgentChannelAction action, {
    String? token,
    String? code,
  }) async {
    if (!supported) return false;
    final String? cleanToken = token?.trim();
    final String? cleanCode = code?.trim();
    _busy.add(agentId);
    _errors.remove(agentId);
    notifyListeners();
    try {
      await _send(<String, dynamic>{
        'type': 'agent_channel_set',
        'agent_id': agentId,
        'channel': kTelegramChannel,
        'action': action.name,
        if (action == AgentChannelAction.enable &&
            cleanToken != null &&
            cleanToken.isNotEmpty)
          'token': cleanToken,
        if (action == AgentChannelAction.link &&
            cleanCode != null &&
            cleanCode.isNotEmpty)
          'code': cleanCode,
      });
      return true;
    } catch (_) {
      _busy.remove(agentId);
      notifyListeners();
      return false;
    }
  }

  /// Takes one `agent_channel` frame for one coworker. A frame with no state
  /// (an unknown coworker, a host without channels) carries only its error.
  void handleFrame(Map<String, dynamic> payload) {
    if (payload['type'] != 'agent_channel') return;
    final Object? channel = payload['channel'];
    if (channel != null && channel != kTelegramChannel) return;
    final Object? agentId = payload['agent_id'];
    if (agentId is! String || agentId.isEmpty) return;
    final Object? error = payload['error'];
    final bool hasError = error is String && error.isNotEmpty;
    final bool hasState =
        payload.containsKey('state') || payload.containsKey('enabled');
    if (!hasState && !hasError) return;
    if (hasState) _states[agentId] = AgentChannelState.fromJson(payload);
    _busy.remove(agentId);
    if (hasError) {
      _errors[agentId] = error;
    } else {
      _errors.remove(agentId);
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
    _states.clear();
    _errors.clear();
    _busy.clear();
  }
}
