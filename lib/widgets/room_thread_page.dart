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

  @override
  State<RoomThreadPage> createState() => _RoomThreadPageState();
}

class _RoomThreadPageState extends State<RoomThreadPage> {
  final List<CoworkRoomTurn> _turns = <CoworkRoomTurn>[];
  CoworkRoomStop? _stop;
  bool _running = true;
  StreamSubscription<CoworkRelayInbound>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.inbound.listen(_onInbound);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
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
    return RoomThreadView(
      roomName: widget.roomName,
      userMessage: widget.userMessage,
      turns: _turns,
      stop: _stop,
      running: _running,
    );
  }
}
