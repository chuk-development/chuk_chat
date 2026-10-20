import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Which chats the user pinned to the top of the roster.
///
/// A pin is the user's arrangement of their inbox, and the inbox is the same
/// on every device — so a pin made on the desktop is expected on the phone.
/// The store is local-first (instant, works signed out) with the signed-in
/// user's Supabase rows behind it:
///
///  * toggling writes the local set at once and pushes it to the user's rows;
///  * on load the REMOTE is the truth, so an unpin on one device does not
///    come back through another device's stale local copy — except for a
///    toggle this device has not pushed yet ([_dirty]), which stands until
///    its push lands. The doc of the first revision promised a union; a
///    union resurrects unpins, and this is the honest version of it;
///  * the pins of the old desktop-only build (kept under a different key,
///    never pushed anywhere) are migrated once and pushed immediately, so
///    the pull that follows cannot mistake them for unpins.
///
/// The remote rows live in `agents_chat_pins`
/// (migrations/agents_chat_pins.sql): one row per pinned id. A deployment
/// without the table yet, or a signed-out session, simply stays local — the
/// same rule the other Agents stores keep.
class RosterPins extends ChangeNotifier {
  RosterPins._();

  static final RosterPins instance = RosterPins._();

  static const String _kKey = 'agents.roster.pinned_v1';

  /// Where the device-local pin store of the old desktop-only build kept its
  /// rows. Read once for the migration, then removed.
  static const String _kLegacyKey = 'agents.desktop.pinned_v1';

  final Set<String> _ids = <String>{};

  /// Ids toggled since the last successful push. They stand against the
  /// remote on pull, so a toggle made offline survives the next load.
  final Set<String> _dirty = <String>{};
  String? _loadedForUserId;
  bool _pushInFlight = false;
  bool _pushAgain = false;

  Set<String> get ids => Set<String>.unmodifiable(_ids);

  bool isPinned(String agentId) => _ids.contains(agentId);

  /// The local key of the signed-in account, or the signed-out shared one.
  /// Pins are the user's inbox arrangement: two accounts on one device do not
  /// share them, and an account switch reloads from that account's key.
  static String _keyFor(String? userId) =>
      userId == null ? _kKey : '$_kKey.$userId';

  /// Loads the pins of the signed-in user. A second call for the same user
  /// is a no-op, unless [force] is set: then the remote is pulled again
  /// (a sync signal from another device), with the same rule as every pull —
  /// the remote is the truth, except for the unpushed toggles in [_dirty].
  Future<void> load({bool force = false}) async {
    String? userId;
    try {
      userId = SupabaseService.auth.currentUser?.id;
    } catch (_) {
      // Supabase not initialised (tests, signed-out web): local only.
    }
    if (_loadedForUserId == userId && _loadedForUserId != null) {
      if (force) await _pullRemote();
      return;
    }
    final bool firstLoad = _loadedForUserId == null && _ids.isEmpty;
    _loadedForUserId = userId;
    _ids.clear();
    Set<String> migrated = const <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final String key = _keyFor(userId);
      String? raw = prefs.getString(key);
      bool fromLegacy = false;
      if (raw == null && firstLoad) {
        // First run on a build that used to be desktop-only: carry the old
        // device-local pins over. They have never been pushed anywhere, so
        // they go out marked dirty (below) — otherwise the pull that follows
        // this load would read their absence from the remote as an unpin.
        raw = prefs.getString(_kLegacyKey);
        fromLegacy = raw != null;
        if (raw != null) {
          await prefs.setString(key, raw);
          await prefs.remove(_kLegacyKey);
        }
      }
      if (raw != null) {
        final Object? data = jsonDecode(raw);
        if (data is List) {
          _ids.addAll(data.whereType<String>());
        }
      }
      if (fromLegacy) {
        migrated = Set<String>.of(_ids);
      }
    } catch (_) {
      // Unreadable pins are no pins.
    }
    _dirty.addAll(migrated);
    notifyListeners();
    if (migrated.isNotEmpty) {
      unawaited(_pushRemote());
    }
    await _pullRemote();
  }

  void toggle(String agentId) {
    if (!_ids.remove(agentId)) _ids.add(agentId);
    _dirty.add(agentId);
    notifyListeners();
    unawaited(_save());
    unawaited(_pushRemote());
  }

  /// True when the last push found a remote to talk to. Purely informational:
  /// a pin that could not be synced is still a pin here, and the next push
  /// carries it.
  bool get syncedRemotely => _syncedRemotely;
  bool _syncedRemotely = false;

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyFor(_loadedForUserId), jsonEncode(_ids.toList()));
    } catch (_) {
      // A pin that is not written is lost on the next launch, nothing more.
    }
  }

  /// The user's pinned ids from Supabase. The remote is the truth — an unpin
  /// on one device must not come back through another device's stale local
  /// copy — with one exception: a toggle this device has not pushed yet
  /// ([_dirty]) stands until its push lands, so working offline cannot lose
  /// what the user just did. Every failure — signed out, no table yet,
  /// offline — is silent: local pins keep working, and the next load tries
  /// again.
  Future<void> _pullRemote() async {
    try {
      final user = SupabaseService.auth.currentUser;
      if (user == null || user.id != _loadedForUserId) return;
      final List<dynamic> rows = await SupabaseService.client
          .from('agents_chat_pins')
          .select('item_id')
          .eq('user_id', user.id);
      final Set<String> remote = <String>{
        for (final Object? row in rows)
          if (row is Map && row['item_id'] is String) row['item_id'] as String,
      };
      final Set<String> next = <String>{
        // Remote truth, minus the ids this device changed without pushing.
        for (final String id in remote)
          if (!_dirty.contains(id)) id,
        // … and the unpushed local toggles, added or removed.
        for (final String id in _ids)
          if (_dirty.contains(id)) id,
      };
      final bool changed = !next.containsAll(_ids) || next.length != _ids.length;
      _ids
        ..clear()
        ..addAll(next);
      if (changed) {
        notifyListeners();
        unawaited(_save());
      }
    } catch (_) {
      // No remote (not signed in, table not deployed yet, offline): local only.
    }
  }

  /// Pushes only the ids this device toggled ([_dirty]): a pinned one is
  /// upserted, an unpinned one deleted. The rest of the user's rows are never
  /// touched, so a pin another device made in the meantime survives — a
  /// whole-set push here would have deleted it (last writer wins on the whole
  /// list). The conflict target is named because the upsert must update an
  /// existing row, and that is what the table's (user_id, item_id) key is for.
  Future<void> _pushRemote() async {
    if (_pushInFlight) {
      _pushAgain = true;
      return;
    }
    _pushInFlight = true;
    final Set<String> pushed = Set<String>.of(_dirty);
    try {
      final user = SupabaseService.auth.currentUser;
      // The set belongs to the account it was loaded for: a push under a
      // different user would write one account's pins into the other's rows.
      if (user == null || user.id != _loadedForUserId) return;
      if (_dirty.isEmpty) return;
      final client = SupabaseService.client;
      final List<String> pinnedDirty = <String>[
        for (final String id in _dirty)
          if (_ids.contains(id)) id,
      ];
      final List<String> unpinnedDirty = <String>[
        for (final String id in _dirty)
          if (!_ids.contains(id)) id,
      ];
      if (pinnedDirty.isNotEmpty) {
        await client.from('agents_chat_pins').upsert(
          <Map<String, dynamic>>[
            for (final String id in pinnedDirty)
              <String, dynamic>{'user_id': user.id, 'item_id': id},
          ],
          onConflict: 'user_id,item_id',
        );
      }
      if (unpinnedDirty.isNotEmpty) {
        await client
            .from('agents_chat_pins')
            .delete()
            .eq('user_id', user.id)
            .inFilter('item_id', unpinnedDirty);
      }
      _syncedRemotely = true;
      // Only the ids this push actually carried leave the dirty set: one
      // toggled while these requests were running was added after the
      // snapshot and is still owed to the remote.
      _dirty.removeAll(pushed);
    } catch (_) {
      // Local pin stands; the next toggle or load pushes again.
    } finally {
      _pushInFlight = false;
      if (_pushAgain) {
        _pushAgain = false;
        unawaited(_pushRemote());
      }
    }
  }

  @visibleForTesting
  void reset() {
    _ids.clear();
    _dirty.clear();
    _loadedForUserId = null;
    _syncedRemotely = false;
    notifyListeners();
  }
}

/// The order every roster shows its agents in — the phone's inbox and the
/// desktop sidebar alike (bead chuk_chat-41k1: the desktop kept creation order
/// while the phone sorted by activity, so the same chat sat on top of one and
/// at the bottom of the other). Pinned first, in the roster's own order; then
/// the rest by last activity, newest first ([compareByLastActivity]), and a
/// agent that has never been active keeps its roster position among the
/// undated ones. Ctrl+1 … Ctrl+9 on the desktop count this list, so the
/// roster and the shortcut can never disagree.
List<AgentsAgent> rosterPinOrder(
  List<AgentsAgent> agents,
  Set<String> pinned,
) {
  final List<AgentsAgent> rest = <AgentsAgent>[
    for (final AgentsAgent a in agents)
      if (!pinned.contains(a.id)) a,
  ];
  // `List.sort` is not stable in Dart; the roster position breaks ties, so
  // equal (or missing) activity never shuffles rows between rebuilds.
  final Map<String, int> position = <String, int>{
    for (var i = 0; i < rest.length; i++) rest[i].id: i,
  };
  rest.sort((AgentsAgent a, AgentsAgent b) {
    final int byActivity = compareByLastActivity(a, b);
    if (byActivity != 0) return byActivity;
    return position[a.id]!.compareTo(position[b.id]!);
  });
  return <AgentsAgent>[
    for (final AgentsAgent a in agents)
      if (pinned.contains(a.id)) a,
    ...rest,
  ];
}

/// Newest activity first; an agent with no activity yet sinks below every
/// dated one. Ties return 0; [rosterPinOrder] breaks them by roster position.
int compareByLastActivity(AgentsAgent a, AgentsAgent b) {
  final DateTime? at = a.lastActivity;
  final DateTime? bt = b.lastActivity;
  if (at == null && bt == null) return 0;
  if (at == null) return 1;
  if (bt == null) return -1;
  return bt.compareTo(at);
}
