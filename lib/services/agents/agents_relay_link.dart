/// The locator that joins Agents's transport to the imported chuk_chat UI.
///
/// The imported chat screens know nothing about [AgentsRelayController]: they
/// call a static `WebSocketChatService.sendStreamingChat(...)` and expect a
/// stream of `ChatStreamEvent`s back. Something has to hand that static method
/// the live controller and the session key it must talk to. That is this file.
///
/// Two properties matter and neither is optional:
///
///  * **The inbound stream outlives the controller.** [AgentsThreadView] builds
///    a *fresh* [AgentsRelayController] on every reconnect (the client is
///    single-shot per socket). A run's adapter subscription is opened once, at
///    the start of the run, and must keep delivering across a reconnect —
///    otherwise a dropped socket silently kills a run that is still going on
///    the host. So [inbound] is a long-lived broadcast controller of our own
///    that [bind] re-points at whichever controller is current.
///  * **The session key is shared.** The adapter is a static method; the
///    imported caller passes `chatId`, which IS the Agents session key, but a
///    caller that passes none (a title generation, a retry) must still land on
///    the thread the user is looking at. [sessionKey] is that fallback.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';

/// Process-wide singleton joining the relay transport to the imported chat UI.
class AgentsRelayLink {
  AgentsRelayLink._();

  /// The one instance every caller uses. Tests reach for it too, and call
  /// [reset] in a tearDown to get a clean slate.
  static final AgentsRelayLink instance = AgentsRelayLink._();

  /// The live transport, or null while nothing is connected. A [ValueNotifier]
  /// so a widget can rebuild when the socket comes and goes.
  final ValueNotifier<AgentsRelayController?> controller =
      ValueNotifier<AgentsRelayController?>(null);

  /// The thread the app is currently pointed at — the executor's `session_key`.
  /// Defaults to `'default'`, the executor's own default session.
  final ValueNotifier<String> sessionKey = ValueNotifier<String>('default');

  /// The long-lived fan-out. Never closed, never replaced: an open subscription
  /// survives every [bind] / [unbind], so a reconnect mid-run does not tear the
  /// adapter (or the replay loader) off the stream.
  final StreamController<AgentsRelayInbound> _fanout =
      StreamController<AgentsRelayInbound>.broadcast(sync: true);

  StreamSubscription<AgentsRelayInbound>? _upstream;

  /// Everything the host says, from whichever controller is bound right now.
  Stream<AgentsRelayInbound> get inbound => _fanout.stream;

  /// Points the link at [next]: the previous upstream subscription is dropped
  /// and [inbound] starts carrying the new controller's events. Idempotent —
  /// binding the same controller twice re-subscribes but changes nothing an
  /// open listener can see.
  void bind(AgentsRelayController next) {
    _upstream?.cancel();
    _upstream = next.inbound.listen(
      _fanout.add,
      // A transport error must not close the fan-out: the next controller has
      // to be able to bind onto the same stream.
      onError: (Object error, StackTrace stack) {
        if (kDebugMode) debugPrint('[agents-link] inbound error: $error');
      },
      cancelOnError: false,
    );
    controller.value = next;
  }

  /// Drops the transport without closing [inbound].
  void unbind() {
    _upstream?.cancel();
    _upstream = null;
    controller.value = null;
  }

  /// Test seam: forget the controller and go back to the default session key.
  @visibleForTesting
  void reset() {
    unbind();
    sessionKey.value = 'default';
  }
}
