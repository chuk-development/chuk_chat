/// Hands the mail key to the host (docs/AGENT_MAIL.md §6.1).
///
/// The host opens the user's sealed mail itself, so it needs the private
/// half of the mail key. The app sends it as one sealed app frame over the
/// end-to-end controller channel:
///
/// ```json
/// {"type": "agent_mail_key", "public_key": "<b64>", "private_key": "<b64>"}
/// ```
///
/// Both values are standard padded base64 of the raw 32-byte X25519 keys;
/// the public key is the one derived from the private key.
///
/// It goes each time the channel to a host comes up, right behind the
/// account token: [AgentsRelayClient] calls [forwardTo] after every
/// provision, the way it forwards the secret set. That moment suits both
/// host paths: the cloud host takes the frame at any time, the local relay
/// path only once the account is provisioned. It goes again right after the
/// app made a new key ([AgentMailService.createdKeys]). The host stores it
/// when it differs from its own copy and answers nothing, so a repeat costs
/// nothing.
///
/// The key never appears in a log line.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agent_mail_crypto.dart';
import 'package:chuk_chat/services/agents/agent_mail_service.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

/// The wire type of the hand-over frame.
const String kAgentMailKeyFrameType = 'agent_mail_key';

/// The hand-over frame for [key].
Map<String, dynamic> agentMailKeyFrame(AgentMailKeyPair key) =>
    <String, dynamic>{
      'type': kAgentMailKeyFrameType,
      'public_key': key.publicKeyBase64,
      'private_key': base64Encode(key.privateKey),
    };

/// Seals and sends one app frame to the host. Throws when not connected.
typedef AgentMailFrameSender = Future<void> Function(
  Map<String, dynamic> payload,
);

/// The sender of the live, paired channel, or null when there is none.
typedef AgentMailChannelSource = AgentMailFrameSender? Function();

AgentMailFrameSender? _linkedChannel() {
  final Object? controller = AgentsRelayLink.instance.controller.value;
  if (controller is! AgentsRelayClient || !controller.state.value.isPaired) {
    return null;
  }
  return controller.sendControlFrame;
}

class AgentMailKeyHandover {
  AgentMailKeyHandover({
    AgentMailService? service,
    AgentMailChannelSource? channel,
  }) : _service = service ?? AgentMailService.instance,
       _channel = channel ?? _linkedChannel;

  /// The app's hand-over, started by the Agents shell.
  static final AgentMailKeyHandover instance = AgentMailKeyHandover();

  final AgentMailService _service;
  final AgentMailChannelSource _channel;

  int _users = 0;
  StreamSubscription<AgentMailKeyPair>? _createdSub;

  /// The hand-overs in order, one at a time.
  Future<void> _chain = Future<void>.value();

  /// Watches for new keys. Only the Agents build has a channel to a host, so
  /// elsewhere this does nothing. Counted: each [start] needs its [stop].
  void start() {
    if (!agentsChatCore) return;
    if (_users++ > 0) return;
    _createdSub = _service.createdKeys.listen(_onCreated);
  }

  void stop() {
    if (_users == 0) return;
    if (--_users > 0) return;
    unawaited(_createdSub?.cancel());
    _createdSub = null;
  }

  /// The relay client's post-provision hook: the channel to the host is up
  /// and the account token is through. Never throws.
  Future<void> forwardTo(AgentsRelayClient client) =>
      handOver(client.sendControlFrame);

  /// Sends [key], or the signed-in user's key (from memory, else
  /// `GET /key`), through [send]. A mailbox without a key sends nothing: the
  /// app makes the key when the user opens the mailbox, and that sends it.
  /// Never throws; a failure waits for the next provision or the next key.
  Future<void> handOver(AgentMailFrameSender send, {AgentMailKeyPair? key}) {
    if (!agentsChatCore) return Future<void>.value();
    final Future<void> next = _chain.then((_) => _sendOnce(send, key));
    _chain = next;
    return next;
  }

  void _onCreated(AgentMailKeyPair key) {
    final AgentMailFrameSender? send = _channel();
    if (send != null) unawaited(handOver(send, key: key));
  }

  Future<void> _sendOnce(
    AgentMailFrameSender send,
    AgentMailKeyPair? given,
  ) async {
    try {
      final AgentMailKeyPair key =
          given ?? _service.cachedKey ?? await _service.mailKey();
      await send(agentMailKeyFrame(key));
    } catch (error) {
      // No key yet, a locked chuk key, offline, or the socket went.
      if (kDebugMode) {
        debugPrint(
          'agent mail: key hand-over skipped (${error.runtimeType}'
          '${error is AgentMailException ? ' ${error.code}' : ''})',
        );
      }
    }
  }
}
