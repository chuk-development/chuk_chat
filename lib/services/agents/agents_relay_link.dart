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

/// Joins one relay transport to the imported chat UI.
///
/// Since CHAT-177 an account can have several computers, and the app keeps one
/// link per computer ([AgentsRelayLinks]). [instance] is the PRIMARY link: the
/// one the thread view drives, for the computer of the conversation on screen.
/// The app-wide services that read "the host" (skills, automations, dashboard,
/// permissions) read it. Work that belongs to one agent asks
/// [AgentsRelayLinks.linkFor] for the link of that agent's computer.
class AgentsRelayLink {
  AgentsRelayLink._();

  /// A link of its own for one computer. Made by [AgentsRelayLinks]; tests
  /// make one directly.
  @visibleForTesting
  AgentsRelayLink.forHost(String hostId) {
    this.hostId.value = hostId;
  }

  /// The primary link. Tests reach for it too, and call [reset] in a
  /// tearDown to get a clean slate.
  static final AgentsRelayLink instance = AgentsRelayLink._();

  /// The computer this link talks to (its relay device id, see
  /// `AgentsStoredPairing.hostId`), or null before one is known. For the
  /// primary link it follows the conversation on screen.
  final ValueNotifier<String?> hostId = ValueNotifier<String?>(null);

  /// Whether the transport is up and paired right now.
  bool get isUp => controller.value?.state.value.isPaired ?? false;

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
    if (identical(this, instance)) hostId.value = null;
  }
}

/// One inbound frame of a secondary link, with the computer it came from.
typedef AgentsHostInbound = ({String hostId, AgentsRelayInbound event});

/// The registry of links, one per paired computer (CHAT-177,
/// docs/agents/MULTI_HOST.md "Connections").
///
/// The primary link ([AgentsRelayLink.instance]) talks to the computer of the
/// conversation on screen. Every other paired computer gets a SECONDARY link
/// of its own, with its own socket, approved devices, controller session and
/// reconnect ([AgentsHostLinks] keeps those sockets up). A frame on a link is
/// always from that link's computer: the relay names the sender and the
/// socket drops what is not its own (`AgentsCloudRelaySocket.acceptsFrameFrom`).
class AgentsRelayLinks extends ChangeNotifier {
  AgentsRelayLinks._();

  static final AgentsRelayLinks instance = AgentsRelayLinks._();

  /// The link of the conversation on screen.
  AgentsRelayLink get primary => AgentsRelayLink.instance;

  /// The primary link's computer, or null before the thread view loaded one.
  String? get primaryHostId => primary.hostId.value;

  final Map<String, AgentsRelayLink> _secondary = <String, AgentsRelayLink>{};
  final Map<String, StreamSubscription<AgentsRelayInbound>> _taps =
      <String, StreamSubscription<AgentsRelayInbound>>{};

  final StreamController<AgentsHostInbound> _secondaryInbound =
      StreamController<AgentsHostInbound>.broadcast(sync: true);

  /// Everything the secondary links receive, each frame tagged with its
  /// computer. The primary link's frames are on `primary.inbound`.
  Stream<AgentsHostInbound> get secondaryInbound => _secondaryInbound.stream;

  /// Makes [hostId] the primary link's computer. Its secondary link, if any,
  /// is dropped: one computer never has two links.
  void setPrimaryHost(String? hostId) {
    if (primary.hostId.value == hostId) return;
    primary.hostId.value = hostId;
    if (hostId != null) _drop(hostId);
    notifyListeners();
  }

  /// The link that talks to [hostId]. Null, an empty id, the primary's own
  /// computer or a primary that has no computer yet all mean the primary.
  AgentsRelayLink linkFor(String? hostId) {
    final String? primaryHost = primary.hostId.value;
    if (hostId == null ||
        hostId.isEmpty ||
        primaryHost == null ||
        primaryHost == hostId) {
      return primary;
    }
    return _secondary.putIfAbsent(hostId, () {
      final AgentsRelayLink link = AgentsRelayLink.forHost(hostId);
      link.controller.addListener(notifyListeners);
      _taps[hostId] = link.inbound.listen(
        (AgentsRelayInbound event) =>
            _secondaryInbound.add((hostId: hostId, event: event)),
      );
      return link;
    });
  }

  /// The secondary link of [hostId] when one exists. Never makes one.
  AgentsRelayLink? secondaryFor(String hostId) => _secondary[hostId];

  /// The computers that have a secondary link.
  Iterable<String> get secondaryHostIds => _secondary.keys;

  /// Whether [controller] is the transport of a secondary link (another
  /// computer than the one on screen).
  bool isSecondaryController(Object controller) {
    for (final AgentsRelayLink link in _secondary.values) {
      if (identical(link.controller.value, controller)) return true;
    }
    return false;
  }

  /// The paired controller of [hostId] (primary or secondary), or null while
  /// its link is down. Never makes a link.
  AgentsRelayController? pairedControllerFor(String hostId) {
    final AgentsRelayLink? link = hostId == primary.hostId.value
        ? primary
        : _secondary[hostId];
    if (link == null || !link.isUp) return null;
    return link.controller.value;
  }

  /// Whether the link of [hostId] is up and paired.
  bool isOnline(String hostId) {
    if (hostId == primary.hostId.value) return primary.isUp;
    return _secondary[hostId]?.isUp ?? false;
  }

  /// Forgets the secondary link of [hostId] (the computer was removed, or
  /// it became the primary). Unbinds it; the controller's owner disposes it.
  void drop(String hostId) {
    if (_drop(hostId)) notifyListeners();
  }

  bool _drop(String hostId) {
    final AgentsRelayLink? link = _secondary.remove(hostId);
    if (link == null) return false;
    unawaited(_taps.remove(hostId)?.cancel());
    link.controller.removeListener(notifyListeners);
    link.unbind();
    return true;
  }

  /// Test seam: no secondary links, no primary computer.
  @visibleForTesting
  void reset() {
    for (final String id in List<String>.of(_secondary.keys)) {
      _drop(id);
    }
    primary.reset();
  }
}
