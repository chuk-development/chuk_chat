/// A live group-room conversation (§16.1/4c): subscribes to the relay client's
/// inbound and accumulates the room's turns into a [RoomThreadView] as they
/// arrive, then names the stop reason when the exchange ends.
///
/// [RoomThreadView] is a pure render; this is the stateful half that turns a
/// stream of `room_turn` / `room_done` events into the list it draws. The stream
/// is injected, so a test drives it with a fake controller and the shell drives
/// it with the real relay socket — the same widget either way.
///
/// **Single open room, for now.** A `room_turn` frame carries no room id (§16.1
/// 4b-relay), so this accumulates every room turn on the stream. That is correct
/// while one room runs at a time — the room the user opened — which is the
/// product model today. When rooms can run concurrently, a room id on the frame
/// and a filter here close the gap; the accumulator does not otherwise change.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/widgets/room_thread_view.dart';

class RoomThreadPage extends StatefulWidget {
  const RoomThreadPage({
    super.key,
    required this.roomName,
    required this.userMessage,
    required this.inbound,
  });

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
          :final round,
          :final agentId,
          :final handle,
          :final text,
        ):
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
      case CoworkRelayRoomDone(:final reason):
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
