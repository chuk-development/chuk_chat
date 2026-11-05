/// Terminal replies of the host to the app's own request frames
/// (docs/WIRE_CONTRACT.md: "Checkpoints, rewind and fork", "Login vault for
/// the browser", "Attachments to Agents").
///
/// These replies are not transcript events, so they do not ride the sealed
/// [AgentsRelayInbound] family. The relay client hands every one of them to
/// [AgentsReplyFrames.instance]; a service that sent a request waits here for
/// its answer with [AgentsReplyFrames.request].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

/// Sends one sealed control frame to the host. Throws when nothing is
/// connected.
typedef AgentsFrameSender = Future<void> Function(Map<String, dynamic> frame);

/// The reply types the bus carries.
const Set<String> kAgentsReplyFrameTypes = <String>{
  'checkpoints',
  'checkpoint_rewound',
  'thread_forked',
  'login_vault',
  'attachment_ack',
};

/// Thrown by [AgentsReplyFrames.request] when no reply came in time.
class AgentsReplyTimeout implements Exception {
  const AgentsReplyTimeout(this.type);

  final String type;

  @override
  String toString() => 'AgentsReplyTimeout($type)';
}

/// Thrown when there is no host link to send a request on.
class AgentsNotConnected implements Exception {
  const AgentsNotConnected();

  @override
  String toString() => 'Not connected to the host';
}

/// The app's one bus of host replies.
class AgentsReplyFrames {
  AgentsReplyFrames();

  static final AgentsReplyFrames instance = AgentsReplyFrames();

  final StreamController<Map<String, dynamic>> _frames =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// Every reply, in arrival order.
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  /// The replies of one [type].
  Stream<Map<String, dynamic>> ofType(String type) =>
      frames.where((Map<String, dynamic> f) => f['type'] == type);

  /// Called by the relay client for every payload of a type in
  /// [kAgentsReplyFrameTypes]; a test calls it to play the host.
  void add(Map<String, dynamic> payload) {
    if (_frames.isClosed) return;
    _frames.add(payload);
  }

  /// Sends [frame] with [send] and completes with the first reply of
  /// [replyType] that [matches] accepts (all of them when null). The
  /// listener is attached BEFORE the frame goes out, so a fast host cannot
  /// answer into the void.
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> frame, {
    required String replyType,
    AgentsFrameSender? send,
    bool Function(Map<String, dynamic> reply)? matches,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final Completer<Map<String, dynamic>> done =
        Completer<Map<String, dynamic>>();
    final StreamSubscription<Map<String, dynamic>> sub = ofType(replyType)
        .listen((Map<String, dynamic> reply) {
          if (done.isCompleted) return;
          if (matches != null && !matches(reply)) return;
          done.complete(reply);
        });
    try {
      await (send ?? sendOverRelay)(frame);
      return await done.future.timeout(
        timeout,
        onTimeout: () => throw AgentsReplyTimeout(replyType),
      );
    } finally {
      // Not awaited: the cancel future of a broadcast subscription belongs to
      // the root zone, so awaiting it would park this request outside the
      // caller's zone (a widget test's fake clock never gets it back).
      unawaited(sub.cancel());
    }
  }

  /// The default sender: the bound relay controller's sealed control frame.
  static Future<void> sendOverRelay(Map<String, dynamic> frame) async {
    final Object? controller = AgentsRelayLink.instance.controller.value;
    if (controller is! AgentsRelayClient) throw const AgentsNotConnected();
    await controller.sendControlFrame(frame);
  }

  @visibleForTesting
  Future<void> close() => _frames.close();
}
