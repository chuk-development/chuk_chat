/// The roster: who your coworkers are, and the one permanent thread each one
/// has. Every agent carries exactly one session; there is no way to open a
/// second (the product decision — one permanent session per bot).
///
/// The host has no roster API over the relay yet, so this source holds what the
/// app itself knows: the one agent that really runs on the paired host, plus any
/// agent the user onboarded in the app. It never invents a coworker, and it
/// marks an app-created agent as not installed on the host ([CoworkAgent.onHost]
/// false) rather than pretending it is live.
///
/// [AgentRosterSource] is the seam a later milestone points at the host's real
/// roster; [LocalAgentRosterSource] is the implementation the app ships with
/// today.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart'
    show CoworkHostAgentName;
import 'package:cowork/services/cowork/schedule_spec.dart';

/// Read/write access to the roster, as a [ChangeNotifier] the UI listens to.
abstract class AgentRosterSource extends ChangeNotifier {
  List<CoworkAgent> get agents;

  /// The ids the user has hidden from the roster (§16.1). Hiding is a view
  /// preference, not a delete: the agent, its threads and any live run stay
  /// exactly as they were, so unhiding brings back the same coworker.
  Set<String> get hiddenIds;

  /// The agents that show in the roster — [agents] minus [hiddenIds].
  List<CoworkAgent> get visibleAgents =>
      <CoworkAgent>[for (final a in agents) if (!hiddenIds.contains(a.id)) a];

  /// The agents the user has hidden, in roster order.
  List<CoworkAgent> get hiddenAgents =>
      <CoworkAgent>[for (final a in agents) if (hiddenIds.contains(a.id)) a];

  /// Hides [id] from the roster. A no-op for an unknown or already-hidden id.
  void hideAgent(String id);

  /// Brings [id] back into the roster. A no-op if it was not hidden.
  void unhideAgent(String id);

  CoworkAgent? byId(String id);

  /// Makes sure the agent that really runs on the paired host is listed, and
  /// returns it. Called once the transport reports a paired host.
  CoworkAgent ensureHostAgent(String peerDeviceId);

  /// Adds a coworker the user just onboarded. The returned agent always has its
  /// one permanent thread, so selecting it opens the conversation immediately.
  CoworkAgent addAgent({
    required String name,
    String? role,
    String? brief,
    ScheduleSpec? schedule,
    List<String> attachmentNames,
  });

  /// Renames a coworker (bead cowork-817). The trimmed name replaces the old
  /// one; an empty name or an unknown id is a no-op. The id and the thread key
  /// never change — a name is a label, not an identity.
  void renameAgent(String id, String name);

  /// Merges the host's `agent_list` (bead cowork-817, WIRE_CONTRACT "Coworker
  /// names"): a known id takes the listed name; an unknown id is added as a
  /// coworker with that name and its one permanent thread; the entry marked
  /// `host` renames the `host:<peerDeviceId>` row (skipped when the host is
  /// not paired). Ids in [ignore] — deleted in this session — are left out.
  /// A list never removes anything.
  void applyHostNames(
    List<CoworkHostAgentName> names, {
    required String? peerDeviceId,
    Set<String> ignore = const <String>{},
  });

  /// Marks a run as in flight (or finished) for [agentId].
  void markRunning(String agentId, bool running);

  /// Records that something happened in a thread at [when].
  void markActivity(String agentId, String threadKey, DateTime when);

  /// Stores the schedule the user set in the app. It changes nothing on the
  /// host — see [CoworkAgent.schedule].
  void setSchedule(String agentId, ScheduleSpec spec);

  void removeAgent(String id);
}

/// In-memory roster.
///
/// Deliberately not persisted: the durable roster lives on the host, and the
/// host does not serve one yet. Writing a local copy to disk would only create a
/// second truth to reconcile later.
class LocalAgentRosterSource extends AgentRosterSource {
  LocalAgentRosterSource({List<CoworkAgent> seed = const <CoworkAgent>[], Random? random})
      : _agents = List<CoworkAgent>.of(seed),
        _random = random ?? Random();

  final List<CoworkAgent> _agents;
  final Random _random;
  final Set<String> _hidden = <String>{};

  @override
  List<CoworkAgent> get agents => List<CoworkAgent>.unmodifiable(_agents);

  @override
  Set<String> get hiddenIds => Set<String>.unmodifiable(_hidden);

  @override
  void hideAgent(String id) {
    if (byId(id) == null) return;
    if (_hidden.add(id)) notifyListeners();
  }

  @override
  void unhideAgent(String id) {
    if (_hidden.remove(id)) notifyListeners();
  }

  @override
  CoworkAgent? byId(String id) {
    for (final agent in _agents) {
      if (agent.id == id) return agent;
    }
    return null;
  }

  /// Makes sure the agent that really runs on the paired host is in the roster.
  ///
  /// Its name is the host's own device id — a real identifier from the pairing,
  /// not a made-up label.
  @override
  CoworkAgent ensureHostAgent(String peerDeviceId) {
    final id = 'host:$peerDeviceId';
    final existing = byId(id);
    if (existing != null) return existing;
    final agent = CoworkAgent(
      id: id,
      name: peerDeviceId,
      onHost: true,
      threads: <CoworkThreadInfo>[
        // One permanent session per bot: its key is the agent id, so the
        // session_key the task rides with is stable across restarts and there
        // is only ever this one.
        CoworkThreadInfo(key: id, title: 'General'),
      ],
    );
    _agents.insert(0, agent);
    notifyListeners();
    return agent;
  }

  @override
  CoworkAgent addAgent({
    required String name,
    String? role,
    String? brief,
    ScheduleSpec? schedule,
    List<String> attachmentNames = const <String>[],
  }) {
    final id = 'local:${name.trim()}:${_agents.length}:${_random.nextInt(1 << 30)}';
    final agent = CoworkAgent(
      id: id,
      name: name.trim(),
      role: (role != null && role.trim().isNotEmpty) ? role.trim() : null,
      brief: (brief != null && brief.trim().isNotEmpty) ? brief.trim() : null,
      schedule: schedule,
      attachmentNames: List<String>.unmodifiable(attachmentNames),
      threads: <CoworkThreadInfo>[
        // One permanent session per bot: its key is the agent id, stable for
        // the life of the coworker.
        CoworkThreadInfo(key: id, title: 'General'),
      ],
    );
    _agents.add(agent);
    notifyListeners();
    return agent;
  }

  @override
  void renameAgent(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final index = _indexOf(id, orNull: true);
    if (index < 0 || _agents[index].name == trimmed) return;
    _agents[index] = _agents[index].copyWith(name: trimmed);
    notifyListeners();
  }

  @override
  void applyHostNames(
    List<CoworkHostAgentName> names, {
    required String? peerDeviceId,
    Set<String> ignore = const <String>{},
  }) {
    var changed = false;
    for (final entry in names) {
      final id = entry.host
          ? (peerDeviceId == null ? null : 'host:$peerDeviceId')
          : entry.agentId;
      if (id == null || ignore.contains(id)) continue;
      final index = _indexOf(id, orNull: true);
      if (index >= 0) {
        if (_agents[index].name == entry.name) continue;
        _agents[index] = _agents[index].copyWith(name: entry.name);
        changed = true;
        continue;
      }
      // The host agent is created by [ensureHostAgent] on pairing, never from
      // a list: a name for a host that is not paired has nowhere to go.
      if (entry.host) continue;
      _agents.add(CoworkAgent(
        id: id,
        name: entry.name,
        threads: <CoworkThreadInfo>[CoworkThreadInfo(key: id, title: 'General')],
      ));
      changed = true;
    }
    if (changed) notifyListeners();
  }

  @override
  void markRunning(String agentId, bool running) {
    final index = _indexOf(agentId, orNull: true);
    if (index < 0 || _agents[index].running == running) return;
    _agents[index] = _agents[index].copyWith(running: running);
    notifyListeners();
  }

  @override
  void markActivity(String agentId, String threadKey, DateTime when) {
    final index = _indexOf(agentId, orNull: true);
    if (index < 0) return;
    final agent = _agents[index];
    _agents[index] = agent.copyWith(
      lastActivity: when,
      threads: <CoworkThreadInfo>[
        for (final thread in agent.threads)
          thread.key == threadKey ? thread.copyWith(lastActivity: when) : thread,
      ],
    );
    notifyListeners();
  }

  @override
  void setSchedule(String agentId, ScheduleSpec spec) {
    final index = _indexOf(agentId, orNull: true);
    if (index < 0) return;
    _agents[index] = _agents[index].copyWith(schedule: spec);
    notifyListeners();
  }

  @override
  void removeAgent(String id) {
    final before = _agents.length;
    _agents.removeWhere((agent) => agent.id == id);
    // Drop any hidden mark too: an id that returns later must not inherit a
    // stale "hidden" state from an agent that no longer exists.
    final wasHidden = _hidden.remove(id);
    if (_agents.length != before || wasHidden) notifyListeners();
  }

  int _indexOf(String agentId, {bool orNull = false}) {
    for (var i = 0; i < _agents.length; i++) {
      if (_agents[i].id == agentId) return i;
    }
    if (orNull) return -1;
    throw ArgumentError.value(agentId, 'agentId', 'No such agent');
  }
}

/// Auto-assigned coworker names (§4): adjective-noun, the same shape the
/// manager's Python generator uses, so a name looks the same wherever it was
/// minted.
class AgentNameGenerator {
  const AgentNameGenerator({Random? random}) : _random = random;

  final Random? _random;

  static const List<String> adjectives = <String>[
    'amber', 'cobalt', 'crimson', 'azure', 'olive', 'violet', 'teal',
    'scarlet', 'indigo', 'coral', 'jade', 'russet', 'slate', 'copper',
    'ivory', 'onyx', 'saffron', 'sable', 'bronze', 'cerulean', 'sienna',
    'pewter', 'lilac', 'ochre', 'brisk', 'quiet', 'swift', 'clever',
    'steady', 'keen',
  ];

  static const List<String> nouns = <String>[
    'otter', 'falcon', 'heron', 'lynx', 'marten', 'raven', 'badger',
    'ferret', 'osprey', 'ibis', 'stoat', 'kestrel', 'weasel', 'plover',
    'shrike', 'tern', 'vole', 'wren',
  ];

  /// A fresh name, avoiding any already in [taken] when it can.
  String next({Iterable<String> taken = const <String>[]}) {
    final random = _random ?? Random();
    final used = taken.toSet();
    for (var attempt = 0; attempt < 32; attempt++) {
      final name = '${adjectives[random.nextInt(adjectives.length)]}-'
          '${nouns[random.nextInt(nouns.length)]}';
      if (!used.contains(name)) return name;
    }
    // Every attempt collided: fall back to a suffix rather than a duplicate.
    return '${adjectives[random.nextInt(adjectives.length)]}-'
        '${nouns[random.nextInt(nouns.length)]}-${used.length + 1}';
  }
}
