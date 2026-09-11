/// A live group-room conversation (§16.1/4c): subscribes to the relay client's
/// inbound and accumulates the room's turns into a [RoomThreadView] as they
/// arrive, then names the stop reason when the exchange ends.
///
/// [RoomThreadView] is a pure render; this is the stateful half that turns a
/// stream of `room_turn` / `room_done` events into the list it draws. The stream
/// is injected, so a test drives it with a fake controller and the shell drives
/// it with the real relay socket — the same widget either way.
///
/// Frames carry a `room_id` (§16.1 4b-relay), so this keeps only the ones for
/// [roomId] and ignores the rest — several rooms can stream over the one socket
/// without crossing wires.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';

import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/room_thread_view.dart';

class RoomThreadPage extends StatefulWidget {
  const RoomThreadPage({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.userMessage,
    required this.inbound,
    this.members = const <CoworkRoomMember>[],
    this.rebind,
    this.onSend,
    this.onReady,
  });

  /// The room this page shows. Frames for any other room on the shared socket
  /// are ignored, so several rooms can stream at once without crossing wires.
  final String roomId;

  final String roomName;

  /// The room's members, shown in the header strip.
  final List<CoworkRoomMember> members;

  /// What the user posted to the room, shown at the top.
  final String userMessage;

  /// The relay client's inbound event stream. Room turns and the room's end are
  /// picked out of it; every other event is ignored here (they belong to the
  /// agent thread).
  final Stream<CoworkRelayInbound> inbound;

  /// The shared transport, if the caller wants the page to follow it. When set,
  /// a reconnect (the value changes to a fresh controller) makes the page
  /// re-subscribe to the new inbound and re-run [onReady] — seamless recovery on
  /// a changing network. When null the page uses [inbound] once and shows the
  /// reconnect banner if that stream dies (the tests' path).
  final ValueListenable<CoworkRelayController?>? rebind;

  /// Sends a message to the room (starts an exchange). When null the composer is
  /// hidden — the page is read-only.
  final void Function(String message)? onSend;

  /// Called once after the page subscribes, so the caller can request the stored
  /// history (which then arrives as a `room_history` event on [inbound]).
  final VoidCallback? onReady;

  @override
  State<RoomThreadPage> createState() => _RoomThreadPageState();
}

class _RoomThreadPageState extends State<RoomThreadPage> {
  final List<CoworkRoomTurn> _turns = <CoworkRoomTurn>[];
  final TextEditingController _composer = TextEditingController();
  CoworkRoomStop? _stop;
  bool _running = true;
  bool _disconnected = false;
  StreamSubscription<CoworkRelayInbound>? _sub;
  // The message the user actually sent, shown at the top once sent. Until then
  // the caller's placeholder ([userMessage]) stands in.
  String? _sentMessage;

  @override
  void initState() {
    super.initState();
    _subscribe(_currentInbound());
    widget.rebind?.addListener(_onRebind);
    // Subscribe first, then ask — so a fast history reply cannot arrive before
    // the listener is attached.
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onReady?.call());
  }

  @override
  void dispose() {
    widget.rebind?.removeListener(_onRebind);
    _sub?.cancel();
    _composer.dispose();
    super.dispose();
  }

  /// The inbound to listen to now: the live controller's when following one,
  /// else the fixed stream passed in.
  Stream<CoworkRelayInbound> _currentInbound() =>
      widget.rebind != null ? _fromRebind() : widget.inbound;

  Stream<CoworkRelayInbound> _fromRebind() {
    final controller = widget.rebind!.value;
    // No controller yet -> a stream that never emits; the rebind listener will
    // swap us onto the real one the moment it arrives.
    return controller?.inbound ?? const Stream<CoworkRelayInbound>.empty();
  }

  void _subscribe(Stream<CoworkRelayInbound> stream) {
    _sub?.cancel();
    _sub = stream.listen(_onInbound, onDone: _onStreamClosed);
  }

  void _onRebind() {
    // The transport changed (a reconnect). Follow it: re-subscribe to the new
    // inbound, drop the disconnected state, and re-run onReady so the room is
    // re-synced and its history re-requested on the fresh socket.
    if (!mounted) return;
    final controller = widget.rebind!.value;
    if (controller == null) {
      _onStreamClosed();
      return;
    }
    setState(() => _disconnected = false);
    _subscribe(controller.inbound);
    widget.onReady?.call();
  }

  Widget _reconnectBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            AppIcon(
              Icons.wifi_off,
              size: 16,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Connection changed. Reopen the room to continue.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _send() {
    final text = _composer.text.trim();
    final onSend = widget.onSend;
    if (text.isEmpty || onSend == null || _disconnected) return;
    onSend(text);
    setState(() {
      _sentMessage = text;
      // A new exchange: clear the previous turns and re-enter the running state.
      _turns.clear();
      _stop = null;
      _running = true;
      _composer.clear();
    });
  }

  void _onInbound(CoworkRelayInbound event) {
    if (!mounted) return;
    switch (event) {
      case CoworkRelayRoomTurn(
        :final roomId,
        :final round,
        :final agentId,
        :final handle,
        :final text,
      ):
        if (roomId != widget.roomId) break; // another room on the same socket
        setState(() {
          _turns.add(
            CoworkRoomTurn(
              round: round,
              agentId: agentId,
              handle: handle,
              text: text,
            ),
          );
        });
      case CoworkRelayRoomHistory(:final roomId, :final turns):
        if (roomId != widget.roomId) break;
        setState(() {
          // History replaces the view: it is the last exchange, and it is over.
          _turns
            ..clear()
            ..addAll(
              turns.map(
                (t) => CoworkRoomTurn(
                  round: t.round,
                  agentId: t.agentId,
                  handle: t.handle,
                  text: t.text,
                ),
              ),
            );
          if (_turns.isNotEmpty) _running = false;
        });
      case CoworkRelayRoomDone(:final roomId, :final reason):
        if (roomId != widget.roomId) break;
        setState(() {
          _stop = CoworkRoomStop.fromWire(reason);
          _running = false;
        });
      default:
        // Not a room event — it belongs to the agent thread, not here.
        break;
    }
  }

  void _onStreamClosed() {
    // The controller's inbound stream closed — the socket was rebuilt (a
    // reconnect on a changing network). This page is bound to the dead stream,
    // so it can receive nothing more; say so plainly rather than hanging on a
    // silent room. Reopening the room binds to the live socket again.
    if (!mounted) return;
    setState(() {
      _disconnected = true;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final thread = RoomThreadView(
      roomName: widget.roomName,
      userMessage: _sentMessage ?? widget.userMessage,
      turns: _turns,
      members: widget.members,
      stop: _stop,
      running: _running,
    );
    final banner = _disconnected ? _reconnectBanner(context) : null;
    if (widget.onSend == null) {
      return banner == null
          ? thread
          : Column(
              children: [
                banner,
                Expanded(child: thread),
              ],
            );
    }
    return Column(
      children: [
        ?banner,
        Expanded(child: thread),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _composer,
                    minLines: 1,
                    maxLines: 4,
                    // Once the socket is gone there is nowhere to send: disable
                    // the field so the user is not typing into a dead room.
                    enabled: !_disconnected,
                    decoration: InputDecoration(
                      hintText: _disconnected
                          ? 'Reopen the room to send'
                          : 'Message the room…',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const AppIcon(Icons.send),
                  onPressed: _disconnected ? null : _send,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
