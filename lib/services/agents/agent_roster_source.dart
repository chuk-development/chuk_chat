/// The roster: who your coworkers are, and the one permanent thread each one
/// has. Every agent carries exactly one session; there is no way to open a
/// second (the product decision — one permanent session per bot).
///
/// The host has no roster API over the relay yet, so this source holds what the
/// app itself knows: the one agent that really runs on the paired host, plus any
/// agent the user onboarded in the app. It never invents a coworker, and it
/// marks an app-created agent as not installed on the host ([AgentsAgent.onHost]
/// false) rather than pretending it is live.
///
/// It IS persisted, through [AgentRosterStore] — as a cache of host truth, not
/// as a second truth. See that file for the rules; the short version is that a
/// received `agent_list` rewrites the snapshot wholesale and a deleted coworker
/// can never come back.
///
/// [AgentRosterSource] is the seam a later milestone points at the host's real
/// roster; [LocalAgentRosterSource] is the implementation the app ships with
/// today.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart'
    show AgentsHostAgentName;
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/services/agents/agent_roster_store.dart';
import 'package:chuk_chat/services/agents/schedule_spec.dart';

/// Read/write access to the roster, as a [ChangeNotifier] the UI listens to.
abstract class AgentRosterSource extends ChangeNotifier {
  List<AgentsAgent> get agents;

  /// Reads whatever this device remembers of the roster, so the shell can land
  /// on the remembered coworker before the socket exists. The default is a
  /// no-op: a source that keeps nothing on disk is already loaded.
  Future<void> load() async {}

  /// The ids the user deleted on this device, across launches. Fed into
  /// [applyHostNames]' `ignore` set, because delete is not on the wire yet and
  /// the host keeps listing a coworker the user removed.
  Set<String> get deletedIds => const <String>{};

  /// The ids the user has hidden from the roster (§16.1). Hiding is a view
  /// preference, not a delete: the agent, its threads and any live run stay
  /// exactly as they were, so unhiding brings back the same coworker.
  Set<String> get hiddenIds;

  /// The agents that show in the roster — [agents] minus [hiddenIds].
  List<AgentsAgent> get visibleAgents => <AgentsAgent>[
    for (final a in agents)
      if (!hiddenIds.contains(a.id)) a,
  ];

  /// The agents the user has hidden, in roster order.
  List<AgentsAgent> get hiddenAgents => <AgentsAgent>[
    for (final a in agents)
      if (hiddenIds.contains(a.id)) a,
  ];

  /// Hides [id] from the roster. A no-op for an unknown or already-hidden id.
  void hideAgent(String id);

  /// Brings [id] back into the roster. A no-op if it was not hidden.
  void unhideAgent(String id);

  AgentsAgent? byId(String id);

  /// Makes sure the agent that really runs on the paired host is listed, and
  /// returns it. Called once the transport reports a paired host.
  AgentsAgent ensureHostAgent(String peerDeviceId);

  /// Adds a coworker the user just onboarded. The returned agent always has its
  /// one permanent thread, so selecting it opens the conversation immediately.
  AgentsAgent addAgent({
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
    List<AgentsHostAgentName> names, {
    required String? peerDeviceId,
    Set<String> ignore = const <String>{},
  });

  /// Marks a run as in flight (or finished) for [agentId].
  void markRunning(String agentId, bool running);

  /// Records that something happened in a thread at [when].
  void markActivity(String agentId, String threadKey, DateTime when);

  /// Stores the schedule the user set in the app. It changes nothing on the
  /// host — see [AgentsAgent.schedule].
  void setSchedule(String agentId, ScheduleSpec spec);

  void removeAgent(String id);

  /// Writes a change that is still waiting to be stored (see [markActivity])
  /// now. Called when the app goes to the background and when the shell
  /// closes. A source with nothing to store does nothing.
  void flushPendingPersist() {}
}

/// The roster the app ships with, kept in memory and cached on disk.
///
/// The durable roster lives on the host. What is written here is a CACHE of it
/// ([AgentRosterStore]): it exists so the first frame of a cold start already
/// has coworkers, and it is overwritten wholesale the moment the host sends its
/// `agent_list`. It is never allowed to outvote the host, and a coworker the
/// user deleted is remembered as deleted so a host list cannot bring it back.
class LocalAgentRosterSource extends AgentRosterSource {
  LocalAgentRosterSource({
    List<AgentsAgent> seed = const <AgentsAgent>[],
    Random? random,
    AgentRosterStore? store,
  }) : _agents = List<AgentsAgent>.of(seed),
       _random = random ?? Random(),
       _store = store ?? AgentRosterStore.instance;

  final List<AgentsAgent> _agents;
  final Random _random;
  final AgentRosterStore _store;
  final Set<String> _hidden = <String>{};
  final Set<String> _deleted = <String>{};
  bool _loaded = false;

  @override
  Set<String> get deletedIds => Set<String>.unmodifiable(_deleted);

  /// Reads the cached roster. Safe to call more than once; an agent already in
  /// memory wins over its stored copy, so a load that lands after a pairing
  /// cannot undo [ensureHostAgent].
  @override
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final AgentRosterSnapshot snapshot = await _store.load();
    _deleted.addAll(snapshot.deleted);
    var changed = false;
    for (final AgentsAgent agent in snapshot.agents) {
      if (_deleted.contains(agent.id)) continue;
      final index = _indexOf(agent.id, orNull: true);
      if (index >= 0) {
        // The agent in memory wins, but it cannot know when the coworker was
        // last active before this launch: take the stored time where it has
        // none.
        final merged = _withStoredActivity(_agents[index], agent);
        if (!identical(merged, _agents[index])) {
          _agents[index] = merged;
          changed = true;
        }
        continue;
      }
      _agents.add(agent);
      changed = true;
    }
    for (final String id in snapshot.hidden) {
      if (_indexOf(id, orNull: true) < 0) continue;
      if (_hidden.add(id)) changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Writes the roster back to the cache. Called after every change that alters
  /// what a cold start should show. The write itself is coalesced and runs in
  /// the background — nothing the user sees waits on it.
  void _persist() {
    // A structural write carries the newest activity too, so a waiting
    // activity write has nothing left to do.
    _activityPersistTimer?.cancel();
    _activityPersistTimer = null;
    _store.saveRoster(_agents, _hidden);
    _store.saveDeleted(_deleted);
  }

  /// The activity write that waits for the end of a burst. A live run marks
  /// activity on every event, and on desktop Linux each preference write
  /// rewrites the whole file on the UI isolate, so activity is written after
  /// [AgentReadMarks.persistDelay] of quiet instead of per event. Structural
  /// changes (add, hide, delete) still write at once.
  Timer? _activityPersistTimer;

  void _schedulePersistActivity() {
    final Duration delay = AgentReadMarks.persistDelay;
    if (delay == Duration.zero) {
      _persist();
      return;
    }
    _activityPersistTimer?.cancel();
    _activityPersistTimer = Timer(delay, _persist);
  }

  @override
  void flushPendingPersist() {
    if (_activityPersistTimer == null) return;
    _persist();
  }

  @override
  void dispose() {
    flushPendingPersist();
    super.dispose();
  }

  @override
  List<AgentsAgent> get agents => List<AgentsAgent>.unmodifiable(_agents);

  @override
  Set<String> get hiddenIds => Set<String>.unmodifiable(_hidden);

  @override
  void hideAgent(String id) {
    if (byId(id) == null) return;
    if (!_hidden.add(id)) return;
    _persist();
    notifyListeners();
  }

  @override
  void unhideAgent(String id) {
    if (!_hidden.remove(id)) return;
    _persist();
    notifyListeners();
  }

  @override
  AgentsAgent? byId(String id) {
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
  AgentsAgent ensureHostAgent(String peerDeviceId) {
    final id = 'host:$peerDeviceId';
    final existing = byId(id);
    if (existing != null) return existing;
    final agent = AgentsAgent(
      id: id,
      name: peerDeviceId,
      onHost: true,
      threads: <AgentsThreadInfo>[
        // One permanent session per bot: its key is the agent id, so the
        // session_key the task rides with is stable across restarts and there
        // is only ever this one.
        AgentsThreadInfo(key: id, title: 'General'),
      ],
    );
    _agents.insert(0, agent);
    _persist();
    notifyListeners();
    return agent;
  }

  @override
  AgentsAgent addAgent({
    required String name,
    String? role,
    String? brief,
    ScheduleSpec? schedule,
    List<String> attachmentNames = const <String>[],
  }) {
    final id =
        'local:${name.trim()}:${_agents.length}:${_random.nextInt(1 << 30)}';
    final agent = AgentsAgent(
      id: id,
      name: name.trim(),
      role: (role != null && role.trim().isNotEmpty) ? role.trim() : null,
      brief: (brief != null && brief.trim().isNotEmpty) ? brief.trim() : null,
      schedule: schedule,
      attachmentNames: List<String>.unmodifiable(attachmentNames),
      threads: <AgentsThreadInfo>[
        // One permanent session per bot: its key is the agent id, stable for
        // the life of the coworker.
        AgentsThreadInfo(key: id, title: 'General'),
      ],
    );
    _agents.add(agent);
    _persist();
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
    _persist();
    notifyListeners();
  }

  @override
  void applyHostNames(
    List<AgentsHostAgentName> names, {
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
      _agents.add(
        AgentsAgent(
          id: id,
          name: entry.name,
          threads: <AgentsThreadInfo>[
            AgentsThreadInfo(key: id, title: 'General'),
          ],
        ),
      );
      changed = true;
    }
    if (!changed) return;
    // The host has spoken: the cache is rewritten from what the roster holds
    // now, so the snapshot can never outvote the next launch's `agent_list`.
    _persist();
    notifyListeners();
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
      threads: <AgentsThreadInfo>[
        for (final thread in agent.threads)
          thread.key == threadKey
              ? thread.copyWith(lastActivity: when)
              : thread,
      ],
    );
    // Stored, so the next cold start shows this time and not "no activity
    // yet". Debounced: a burst of events costs one write.
    _schedulePersistActivity();
    notifyListeners();
  }

  /// [memory] with the stored [stored] activity times filled in where
  /// [memory] has none. Returns [memory] itself when nothing was missing.
  static AgentsAgent _withStoredActivity(AgentsAgent memory, AgentsAgent stored) {
    final storedThreads = <String, DateTime?>{
      for (final thread in stored.threads) thread.key: thread.lastActivity,
    };
    var changed = false;
    final threads = <AgentsThreadInfo>[
      for (final thread in memory.threads)
        if (thread.lastActivity == null && storedThreads[thread.key] != null)
          (() {
            changed = true;
            return thread.copyWith(lastActivity: storedThreads[thread.key]);
          })()
        else
          thread,
    ];
    final agentAt = memory.lastActivity ?? stored.lastActivity;
    if (!changed && agentAt == memory.lastActivity) return memory;
    return memory.copyWith(lastActivity: agentAt, threads: threads);
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
    final existed = _agents.length != before;
    // Remembered for good: delete has no wire frame yet, so the host keeps
    // listing this coworker and every later `agent_list` has to skip it.
    final newlyDeleted = existed && _deleted.add(id);
    if (!existed && !wasHidden && !newlyDeleted) return;
    _persist();
    notifyListeners();
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
    'amber',
    'cobalt',
    'crimson',
    'azure',
    'olive',
    'violet',
    'teal',
    'scarlet',
    'indigo',
    'coral',
    'jade',
    'russet',
    'slate',
    'copper',
    'ivory',
    'onyx',
    'saffron',
    'sable',
    'bronze',
    'cerulean',
    'sienna',
    'pewter',
    'lilac',
    'ochre',
    'brisk',
    'quiet',
    'swift',
    'clever',
    'steady',
    'keen',
  ];

  static const List<String> nouns = <String>[
    'otter',
    'falcon',
    'heron',
    'lynx',
    'marten',
    'raven',
    'badger',
    'ferret',
    'osprey',
    'ibis',
    'stoat',
    'kestrel',
    'weasel',
    'plover',
    'shrike',
    'tern',
    'vole',
    'wren',
  ];

  /// A fresh name, avoiding any already in [taken] when it can.
  String next({Iterable<String> taken = const <String>[]}) {
    final random = _random ?? Random();
    final used = taken.toSet();
    for (var attempt = 0; attempt < 32; attempt++) {
      final name =
          '${adjectives[random.nextInt(adjectives.length)]}-'
          '${nouns[random.nextInt(nouns.length)]}';
      if (!used.contains(name)) return name;
    }
    // Every attempt collided: fall back to a suffix rather than a duplicate.
    return '${adjectives[random.nextInt(adjectives.length)]}-'
        '${nouns[random.nextInt(nouns.length)]}-${used.length + 1}';
  }
}
