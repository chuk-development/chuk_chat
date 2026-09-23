/// The rooms the app knows about (§16.1/4c). A group room is several coworkers
/// in one conversation; this is where the app holds the ones the user built.
///
/// Like [LocalAgentRosterSource], the durable roster lives on the host — the
/// host is what actually runs a room — so this in-memory source is deliberately
/// not persisted. It exists so the create-room flow has somewhere to put a new
/// room and the UI has something to list, until the host serves rooms of its
/// own. It never invents a room. There is no member ceiling — a room takes as
/// many coworkers as the roster holds — but the floor still holds: a room needs
/// a name and at least two distinct members, and one that drops below two is
/// deleted.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/agents_room.dart';

/// Read/write access to the app's rooms, as a [ChangeNotifier] the UI listens to.
abstract class RoomSource extends ChangeNotifier {
  List<AgentsRoom> get rooms;

  AgentsRoom? byId(String id);

  /// Renames a room. A no-op for an unknown id or an empty/blank name.
  void renameRoom(String id, String name);

  /// Sets the room's "coworkers may reply to each other" policy
  /// (`agent_to_agent`). A no-op for an unknown id; notifies on a real change.
  /// The host is told separately — this only moves the app's own copy.
  void setAgentToAgent(String roomId, bool enabled);

  /// Adds a member to a room. A no-op for an unknown room or a duplicate
  /// agent/handle. There is no member ceiling.
  void addMemberToRoom(String roomId, AgentsRoomMember member);

  /// Removes a member from a room. A room that drops below two members is
  /// deleted; returns true if the room itself was deleted.
  bool removeMemberFromRoom(String roomId, String agentId);

  /// Removes [agentId] from every room it is in. A room that drops below two
  /// members is deleted (a room of one is not a room). Called when an agent is
  /// deleted, so no room keeps a phantom member. Returns the ids of rooms that
  /// were deleted as a result.
  List<String> removeAgentFromRooms(String agentId);

  /// Creates a room from a draft, assigning an id. Throws [ArgumentError] if the
  /// draft breaks a rule (no name, fewer than two members, a duplicate handle or
  /// agent) — the same rules the host enforces, checked here so a broken room
  /// never reaches it. There is no upper bound on the member count.
  AgentsRoom addRoom(AgentsRoomDraft draft);

  void removeRoom(String id);
}

/// In-memory room source.
class LocalRoomSource extends RoomSource {
  LocalRoomSource({
    List<AgentsRoom> seed = const <AgentsRoom>[],
    Random? random,
  }) : _rooms = List<AgentsRoom>.of(seed),
       _random = random ?? Random();

  final List<AgentsRoom> _rooms;
  final Random _random;

  @override
  List<AgentsRoom> get rooms => List<AgentsRoom>.unmodifiable(_rooms);

  @override
  AgentsRoom? byId(String id) {
    for (final room in _rooms) {
      if (room.id == id) return room;
    }
    return null;
  }

  @override
  AgentsRoom addRoom(AgentsRoomDraft draft) {
    final name = draft.name.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(draft.name, 'name', 'a room needs a name');
    }
    final members = draft.members;
    if (members.length < 2) {
      throw ArgumentError.value(
        members.length,
        'members',
        'a room needs at least two members',
      );
    }
    final handles = members.map((m) => m.handle).toSet();
    if (handles.length != members.length) {
      throw ArgumentError('two members share a handle');
    }
    final agentIds = members.map((m) => m.agentId).toSet();
    if (agentIds.length != members.length) {
      throw ArgumentError('an agent is in the room twice');
    }
    final room = AgentsRoom(
      id: 'room:${_random.nextInt(1 << 32)}',
      name: name,
      members: List<AgentsRoomMember>.unmodifiable(members),
      agentToAgent: draft.agentToAgent,
    );
    _rooms.add(room);
    notifyListeners();
    return room;
  }

  @override
  void renameRoom(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    for (var i = 0; i < _rooms.length; i++) {
      if (_rooms[i].id == id) {
        if (_rooms[i].name == trimmed) return;
        _rooms[i] = _rooms[i].copyWith(name: trimmed);
        notifyListeners();
        return;
      }
    }
  }

  @override
  void setAgentToAgent(String roomId, bool enabled) {
    for (var i = 0; i < _rooms.length; i++) {
      if (_rooms[i].id != roomId) continue;
      if (_rooms[i].agentToAgent == enabled) return;
      _rooms[i] = _rooms[i].copyWith(agentToAgent: enabled);
      notifyListeners();
      return;
    }
  }

  @override
  List<String> removeAgentFromRooms(String agentId) {
    final deleted = <String>[];
    var changed = false;
    for (var i = _rooms.length - 1; i >= 0; i--) {
      final room = _rooms[i];
      if (!room.members.any((m) => m.agentId == agentId)) continue;
      final kept = <AgentsRoomMember>[
        for (final m in room.members)
          if (m.agentId != agentId) m,
      ];
      changed = true;
      if (kept.length < 2) {
        deleted.add(room.id);
        _rooms.removeAt(i);
      } else {
        _rooms[i] = room.copyWith(
          members: List<AgentsRoomMember>.unmodifiable(kept),
        );
      }
    }
    if (changed) notifyListeners();
    return deleted;
  }

  @override
  void addMemberToRoom(String roomId, AgentsRoomMember member) {
    for (var i = 0; i < _rooms.length; i++) {
      final room = _rooms[i];
      if (room.id != roomId) continue;
      if (room.members.any(
        (m) => m.agentId == member.agentId || m.handle == member.handle,
      )) {
        return;
      }
      _rooms[i] = room.copyWith(
        members: List<AgentsRoomMember>.unmodifiable(<AgentsRoomMember>[
          ...room.members,
          member,
        ]),
      );
      notifyListeners();
      return;
    }
  }

  @override
  bool removeMemberFromRoom(String roomId, String agentId) {
    for (var i = 0; i < _rooms.length; i++) {
      final room = _rooms[i];
      if (room.id != roomId) continue;
      if (!room.members.any((m) => m.agentId == agentId)) return false;
      final kept = <AgentsRoomMember>[
        for (final m in room.members)
          if (m.agentId != agentId) m,
      ];
      if (kept.length < 2) {
        _rooms.removeAt(i);
        notifyListeners();
        return true;
      }
      _rooms[i] = room.copyWith(
        members: List<AgentsRoomMember>.unmodifiable(kept),
      );
      notifyListeners();
      return false;
    }
    return false;
  }

  @override
  void removeRoom(String id) {
    final before = _rooms.length;
    _rooms.removeWhere((room) => room.id == id);
    if (_rooms.length != before) notifyListeners();
  }
}
