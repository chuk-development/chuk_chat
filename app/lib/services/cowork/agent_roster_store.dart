/// The persisted snapshot of the roster — a CACHE of host truth, never a
/// second truth.
///
/// ## Why this exists
///
/// The roster used to live in memory only, so every launch started with an
/// EMPTY list of coworkers. The shell remembers which coworker and which
/// thread the user was in (`cowork.last_agent_id` / `cowork.last_thread_key`),
/// but it can only land on that coworker if the coworker is in the roster —
/// and on a cold start it was not. The user therefore waited for the relay to
/// pair and for the host's `agent_list` before their conversation appeared,
/// although the transcript itself was already on disk. This store closes that
/// gap: the roster is read from `SharedPreferences` before the first frame, so
/// the remembered thread mounts from the local cache with no socket at all.
///
/// ## The rules
///
///  * The host stays the truth. A received `agent_list` is applied to the
///    roster and the roster is then written here WHOLESALE — the snapshot can
///    never outvote the host, it only fills the gap before the host speaks.
///  * A deleted coworker may not come back. Delete is not on the wire yet
///    (docs/WIRE_CONTRACT.md, "Coworker names"), so the host keeps listing a
///    coworker the user removed. The deleted ids are persisted next to the
///    agents and fed back into `applyHostNames`' `ignore` set on the next
///    launch, exactly as they are within a session.
///  * Only roster facts are stored: id, name, whether the agent runs on the
///    host, its threads and whether the user hid it. A picture, a colour, a
///    role line and a brief are display data and live in [AgentProfileStore].
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/models/cowork_agent.dart';

/// The one preferences key this store owns.
const String kAgentRosterPrefsKey = 'cowork_agent_roster_v1';

/// What one launch reads back off disk.
@immutable
class AgentRosterSnapshot {
  const AgentRosterSnapshot({
    this.agents = const <CoworkAgent>[],
    this.hidden = const <String>{},
    this.deleted = const <String>{},
  });

  final List<CoworkAgent> agents;

  /// The ids the user hid from the roster.
  final Set<String> hidden;

  /// The ids the user deleted. Kept for good, so a host list cannot resurrect
  /// a coworker the user removed on an earlier launch.
  final Set<String> deleted;

  bool get isEmpty => agents.isEmpty && deleted.isEmpty;
}

class AgentRosterStore {
  AgentRosterStore({String prefsKey = kAgentRosterPrefsKey})
    : _prefsKey = prefsKey;

  /// The process-wide store. A test builds its own with its own key.
  static final AgentRosterStore instance = AgentRosterStore();

  final String _prefsKey;

  List<CoworkAgent> _agents = const <CoworkAgent>[];
  Set<String> _hidden = const <String>{};
  Set<String> _deleted = const <String>{};
  bool _loaded = false;

  /// One write chain, so two mutations in the same turn cost one write and a
  /// slow write can never be overtaken by an older one.
  Future<void> _chain = Future<void>.value();
  bool _queued = false;

  bool get loaded => _loaded;

  /// Reads the snapshot. Never throws: a store that cannot be read is an
  /// empty roster, which is exactly what the app had before this file.
  Future<AgentRosterSnapshot> load() async {
    // What is on disk is the whole answer. Anything this object still held
    // from an earlier read is dropped first, so an empty store really reads
    // back as an empty roster rather than as "whatever I remembered".
    _agents = const <CoworkAgent>[];
    _hidden = const <String>{};
    _deleted = const <String>{};
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map) {
          final List<CoworkAgent> agents = <CoworkAgent>[];
          final Set<String> hidden = <String>{};
          final dynamic rows = decoded['agents'];
          if (rows is List) {
            for (final dynamic row in rows) {
              if (row is! Map) continue;
              final CoworkAgent? agent = _readAgent(
                Map<String, dynamic>.from(row),
              );
              if (agent == null) continue;
              agents.add(agent);
              if (row['hidden'] == true) hidden.add(agent.id);
            }
          }
          _agents = List<CoworkAgent>.unmodifiable(agents);
          _hidden = Set<String>.unmodifiable(hidden);
          _deleted = Set<String>.unmodifiable(_readIds(decoded['deleted']));
        }
      }
    } catch (error) {
      debugPrint('⚠️ [AgentRosterStore] load failed: $error');
    }
    _loaded = true;
    return AgentRosterSnapshot(
      agents: _agents,
      hidden: _hidden,
      deleted: _deleted,
    );
  }

  /// Replaces the stored roster with [agents] / [hidden] and writes it in the
  /// background. Wholesale on purpose: the roster in memory has just been
  /// reconciled with the host, so anything the snapshot still held is stale.
  void saveRoster(Iterable<CoworkAgent> agents, Set<String> hidden) {
    _agents = List<CoworkAgent>.unmodifiable(agents);
    _hidden = Set<String>.unmodifiable(hidden);
    _schedule();
  }

  /// Replaces the stored set of deleted ids.
  void saveDeleted(Set<String> deleted) {
    _deleted = Set<String>.unmodifiable(deleted);
    _schedule();
  }

  /// Completes when the write queued by the last save is on disk. For tests
  /// and for a deliberate flush; nothing the user sees waits on it.
  Future<void> flush() => _chain;

  /// Drops everything, in memory and on disk.
  Future<void> clear() {
    _agents = const <CoworkAgent>[];
    _hidden = const <String>{};
    _deleted = const <String>{};
    _loaded = false;
    _schedule();
    return _chain;
  }

  // ---------------------------------------------------------------------------

  void _schedule() {
    if (_queued) return;
    _queued = true;
    _chain = _chain.then((_) async {
      _queued = false;
      await _persist();
    });
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_agents.isEmpty && _deleted.isEmpty) {
        await prefs.remove(_prefsKey);
        return;
      }
      final Map<String, dynamic> out = <String, dynamic>{
        'agents': <Map<String, dynamic>>[
          for (final CoworkAgent agent in _agents)
            <String, dynamic>{
              'id': agent.id,
              'name': agent.name,
              'onHost': agent.onHost,
              'threads': <Map<String, dynamic>>[
                for (final CoworkThreadInfo thread in agent.threads)
                  <String, dynamic>{'key': thread.key, 'title': thread.title},
              ],
              if (_hidden.contains(agent.id)) 'hidden': true,
            },
        ],
        if (_deleted.isNotEmpty) 'deleted': _deleted.toList(),
      };
      await prefs.setString(_prefsKey, jsonEncode(out));
    } catch (error) {
      // No preferences (a widget test, a locked store): the roster is still
      // correct in memory, only the next launch loses its head start.
      debugPrint('⚠️ [AgentRosterStore] persist failed: $error');
    }
  }

  static CoworkAgent? _readAgent(Map<String, dynamic> row) {
    final Object? id = row['id'];
    if (id is! String || id.isEmpty) return null;
    final Object? name = row['name'];
    final List<CoworkThreadInfo> threads = <CoworkThreadInfo>[];
    final Object? rows = row['threads'];
    if (rows is List) {
      for (final Object? entry in rows) {
        if (entry is! Map) continue;
        final Object? key = entry['key'];
        if (key is! String || key.isEmpty) continue;
        threads.add(
          CoworkThreadInfo(
            key: key,
            title: entry['title'] is String
                ? entry['title'] as String
                : 'General',
          ),
        );
      }
    }
    if (threads.isEmpty) {
      // One permanent session per bot: its key is the agent id. A row without
      // a thread would select a coworker with nothing to open.
      threads.add(CoworkThreadInfo(key: id, title: 'General'));
    }
    return CoworkAgent(
      id: id,
      name: name is String && name.isNotEmpty ? name : id,
      onHost: row['onHost'] == true,
      threads: threads,
    );
  }

  static Set<String> _readIds(Object? value) {
    if (value is! List) return <String>{};
    return <String>{
      for (final Object? entry in value)
        if (entry is String && entry.isNotEmpty) entry,
    };
  }
}
