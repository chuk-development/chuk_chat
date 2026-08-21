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

import 'package:flutter/material.dart';

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
    this.onSend,
  });

  /// The room this page shows. Frames for any other room on the shared socket
  /// are ignored, so several rooms can stream at once without crossing wires.
  final String roomId;

  final String roomName;

  /// What the user posted to the room, shown at the top.
  final String userMessage;

  /// The relay client's inbound event stream. Room turns and the room's end are
  /// picked out of it; every other event is ignored here (they belong to the
  /// agent thread).
  final Stream<CoworkRelayInbound> inbound;

  /// Sends a message to the room (starts an exchange). When null the composer is
  /// hidden — the page is read-only.
  final void Function(String message)? onSend;

  @override
  State<RoomThreadPage> createState() => _RoomThreadPageState();
}

class _RoomThreadPageState extends State<RoomThreadPage> {
  final List<CoworkRoomTurn> _turns = <CoworkRoomTurn>[];
  final TextEditingController _composer = TextEditingController();
  CoworkRoomStop? _stop;
  bool _running = true;
  StreamSubscription<CoworkRelayInbound>? _sub;
  // The message the user actually sent, shown at the top once sent. Until then
  // the caller's placeholder ([userMessage]) stands in.
  String? _sentMessage;

  @override
  void initState() {
    super.initState();
    _sub = widget.inbound.listen(_onInbound);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _composer.dispose();
    super.dispose();
  }

  void _send() {
    final text = _composer.text.trim();
    final onSend = widget.onSend;
    if (text.isEmpty || onSend == null) return;
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

  @override
  Widget build(BuildContext context) {
    final thread = RoomThreadView(
      roomName: widget.roomName,
      userMessage: _sentMessage ?? widget.userMessage,
      turns: _turns,
      stop: _stop,
      running: _running,
    );
    if (widget.onSend == null) return thread;
    return Column(
      children: [
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
                    decoration: const InputDecoration(
                      hintText: 'Message the room…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
