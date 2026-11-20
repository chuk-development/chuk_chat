/// The rooms the app knows about (§16.1/4c). A group room is several agents
/// in one conversation; this is where the app holds the ones the user built.
///
/// The host is the source of truth: it keeps every group and answers a
/// `room_list_request` with all of them ([RoomSource.applyHostRooms] merges
/// that in). The app keeps a small local copy too ([RoomStore], a JSON list in
/// SharedPreferences), so the list shows at start before the host answers and
/// a group made while the host was away survives a restart. It never invents a
/// room. There is no member ceiling — a room takes as
/// many agents as the roster holds — but the floor still holds: a room needs
/// a name and at least two distinct members, and one that drops below two is
/// deleted.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_room.dart';

/// Where [LocalRoomSource] keeps its local copy of the groups.
abstract class RoomStore {
  /// The stored groups; empty when nothing is stored or it cannot be read.
  Future<List<AgentsRoom>> load();

  Future<void> save(List<AgentsRoom> rooms);
}

/// [RoomStore] on SharedPreferences: one small JSON list (names, members and
/// settings only; a conversation is never stored here).
class SharedPrefsRoomStore implements RoomStore {
  const SharedPrefsRoomStore({this.key = 'agents.rooms_v1'});

  final String key;

  @override
  Future<List<AgentsRoom>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return const <AgentsRoom>[];
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <AgentsRoom>[];
      return <AgentsRoom>[
        for (final Object? entry in decoded) ?AgentsRoom.fromJson(entry),
      ];
    } catch (_) {
      // A broken copy is no copy: the host's list fills the gap.
      return const <AgentsRoom>[];
    }
  }

  @override
  Future<void> save(List<AgentsRoom> rooms) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode(<Object?>[for (final room in rooms) room.toJson()]),
      );
    } catch (_) {
      // The local copy is a convenience; the host keeps the groups.
    }
  }
}

/// Read/write access to the app's rooms, as a [ChangeNotifier] the UI listens to.
abstract class RoomSource extends ChangeNotifier {
  List<AgentsRoom> get rooms;

  AgentsRoom? byId(String id);

  /// Renames a room. A no-op for an unknown id or an empty/blank name.
  void renameRoom(String id, String name);

  /// Changes a group's settings. A null argument keeps the current value; an
  /// empty [leadAgentId] / [fallbackAgentId] clears that member. A no-op for
  /// an unknown id; notifies on a real change. The host is told separately.
  void updateRoomSettings(
    String roomId, {
    AgentsRoomResponder? responder,
    String? leadAgentId,
    String? fallbackAgentId,
    String? bulletin,
    String? workdir,
  });

  /// Merges the host's `room_list`: adds the groups this app lacks and takes
  /// the host's name, members and settings for the ones it has (the host is
  /// the source of truth). A local group the host does not list is kept: it is
  /// pushed with the next `room_create` when it is opened.
  void applyHostRooms(List<AgentsRoom> hostRooms);

  /// Sets the room's "agents may reply to each other" policy
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

/// The app's room source: in memory, with an optional local copy in [store].
class LocalRoomSource extends RoomSource {
  LocalRoomSource({
    List<AgentsRoom> seed = const <AgentsRoom>[],
    Random? random,
    RoomStore? store,
  }) : _rooms = List<AgentsRoom>.of(seed),
       _random = random ?? Random(),
       _store = store {
    if (store != null) ready = _restore(store);
  }

  final List<AgentsRoom> _rooms;
  final Random _random;
  final RoomStore? _store;
  bool _disposed = false;

  /// Completes once the local copy is read (at once without a store).
  Future<void> ready = Future<void>.value();

  Future<void> _restore(RoomStore store) async {
    final stored = await store.load();
    if (_disposed || stored.isEmpty) return;
    var added = false;
    for (final room in stored) {
      // Something made or listed while the copy was read wins over it.
      if (byId(room.id) != null) continue;
      _rooms.add(room);
      added = true;
    }
    if (added) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
    final store = _store;
    if (store != null) unawaited(store.save(List<AgentsRoom>.of(_rooms)));
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void updateRoomSettings(
    String roomId, {
    AgentsRoomResponder? responder,
    String? leadAgentId,
    String? fallbackAgentId,
    String? bulletin,
    String? workdir,
  }) {
    for (var i = 0; i < _rooms.length; i++) {
      final room = _rooms[i];
      if (room.id != roomId) continue;
      final next = room.copyWith(
        responder: responder,
        leadAgentId: leadAgentId == null || leadAgentId.isEmpty
            ? null
            : leadAgentId,
        clearLead: leadAgentId != null && leadAgentId.isEmpty,
        fallbackAgentId: fallbackAgentId == null || fallbackAgentId.isEmpty
            ? null
            : fallbackAgentId,
        clearFallback: fallbackAgentId != null && fallbackAgentId.isEmpty,
        bulletin: bulletin,
        workdir: workdir,
      );
      if (_sameRoom(next, room)) return;
      _rooms[i] = next;
      notifyListeners();
      return;
    }
  }

  @override
  void applyHostRooms(List<AgentsRoom> hostRooms) {
    var changed = false;
    for (final host in hostRooms) {
      final i = _rooms.indexWhere((r) => r.id == host.id);
      if (i < 0) {
        _rooms.add(host);
        changed = true;
      } else if (!_sameRoom(_rooms[i], host)) {
        _rooms[i] = host;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  static bool _sameRoom(AgentsRoom a, AgentsRoom b) =>
      jsonEncode(a.toJson()) == jsonEncode(b.toJson());

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
      responder: draft.responder,
      leadAgentId: draft.leadAgentId,
      fallbackAgentId: draft.fallbackAgentId,
      bulletin: draft.bulletin.length > kRoomBulletinMaxChars
          ? draft.bulletin.substring(0, kRoomBulletinMaxChars)
          : draft.bulletin,
      workdir: draft.workdir.trim(),
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
