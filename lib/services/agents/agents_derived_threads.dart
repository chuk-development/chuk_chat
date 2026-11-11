/// Chats an automation made of its own (docs/WIRE_CONTRACT.md, "Automation
/// guards and schedule targets", "Schedule target").
///
/// A schedule with target `new_once` runs in one chat of its own,
/// `<owner>#auto-<id>`; one with target `new` runs in a new chat per fire,
/// `<owner>#auto-<id>-<n>`. The host names the chat on the `fired` event
/// (`run_session_key`). The inbox lists each one as a thread of its own under
/// the owning agent, titled with the automation's name.
///
/// Kept on the device, so the inbox still lists them after a restart; the
/// transcript of each one comes from the host like any thread's.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One chat an automation made.
@immutable
class AgentsDerivedThread {
  const AgentsDerivedThread({
    required this.key,
    required this.ownerKey,
    required this.title,
    this.lastActivity,
  });

  /// The chat's session key (`<owner>#auto-<id>` or `...-<n>`).
  final String key;

  /// The owning agent's thread key (the part before `#auto-`).
  final String ownerKey;

  /// The automation's name, with the fire number for a chat per fire.
  final String title;
  final DateTime? lastActivity;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'key': key,
    'owner': ownerKey,
    'title': title,
    if (lastActivity != null) 'at': lastActivity!.toUtc().toIso8601String(),
  };

  static AgentsDerivedThread? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? key = raw['key'];
    final Object? owner = raw['owner'];
    final Object? title = raw['title'];
    final Object? at = raw['at'];
    if (key is! String || owner is! String || key.isEmpty) return null;
    return AgentsDerivedThread(
      key: key,
      ownerKey: owner,
      title: title is String && title.isNotEmpty ? title : key,
      lastActivity: at is String ? DateTime.tryParse(at)?.toLocal() : null,
    );
  }
}

class AgentsDerivedThreads extends ChangeNotifier {
  AgentsDerivedThreads();

  static AgentsDerivedThreads instance = AgentsDerivedThreads();

  static const String _prefsKey = 'agents_derived_threads_v1';

  /// The marker the host puts between the owner and the automation id.
  static const String marker = '#auto-';

  final Map<String, AgentsDerivedThread> _byKey =
      <String, AgentsDerivedThread>{};
  bool _loaded = false;

  /// True for a chat an automation made.
  static bool isDerivedKey(String key) => key.contains(marker);

  /// The owning thread of [key], or null for a key that is not derived.
  static String? ownerOf(String key) {
    final int at = key.indexOf(marker);
    return at <= 0 ? null : key.substring(0, at);
  }

  /// The chats of [ownerKey], newest first.
  List<AgentsDerivedThread> forOwner(String ownerKey) {
    final List<AgentsDerivedThread> list = <AgentsDerivedThread>[
      for (final AgentsDerivedThread t in _byKey.values)
        if (t.ownerKey == ownerKey) t,
    ];
    list.sort((AgentsDerivedThread a, AgentsDerivedThread b) {
      final DateTime? x = a.lastActivity;
      final DateTime? y = b.lastActivity;
      if (x == null && y == null) return a.key.compareTo(b.key);
      if (x == null) return 1;
      if (y == null) return -1;
      return y.compareTo(x);
    });
    return list;
  }

  AgentsDerivedThread? byKey(String key) => _byKey[key];

  /// Reads the stored list once. Safe to call often.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      bool added = false;
      for (final Object? entry in decoded) {
        final AgentsDerivedThread? t = AgentsDerivedThread.fromJson(entry);
        if (t != null && !_byKey.containsKey(t.key)) {
          _byKey[t.key] = t;
          added = true;
        }
      }
      if (added) notifyListeners();
    } catch (_) {
      // No preferences (a widget test): the list starts empty.
    }
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(<Map<String, dynamic>>[
          for (final AgentsDerivedThread t in _byKey.values) t.toJson(),
        ]),
      );
    } catch (_) {
      // Kept in memory; the next fire writes again.
    }
  }

  /// Takes one `automation` frame. A `fired` event that names a run in
  /// another chat (`run_session_key` with `#auto-`) adds that chat.
  void ingestAutomation(Map<String, dynamic> payload, {DateTime? now}) {
    if (payload['type'] != 'automation') return;
    final Object? runKey = payload['run_session_key'];
    if (runKey is! String || !isDerivedKey(runKey)) return;
    final Object? owner = payload['session_key'];
    final String? ownerKey = owner is String && owner.isNotEmpty
        ? owner
        : ownerOf(runKey);
    if (ownerKey == null) return;
    final Object? rawName = payload['name'];
    final String name = rawName is String && rawName.trim().isNotEmpty
        ? rawName.trim()
        : (payload['id'] is String ? payload['id'] as String : runKey);
    // `new`: one chat per fire, `<owner>#auto-<id>-<n>`. The number tells
    // the chats of one automation apart.
    final Object? id = payload['id'];
    String title = name;
    if (id is String && id.isNotEmpty) {
      final String once = '$ownerKey$marker$id';
      if (runKey != once && runKey.startsWith('$once-')) {
        title = '$name · ${runKey.substring(once.length + 1)}';
      }
    }
    final DateTime at = now ?? DateTime.now();
    final AgentsDerivedThread? before = _byKey[runKey];
    if (before != null &&
        before.title == title &&
        before.ownerKey == ownerKey &&
        before.lastActivity != null &&
        !at.isAfter(before.lastActivity!)) {
      return;
    }
    _byKey[runKey] = AgentsDerivedThread(
      key: runKey,
      ownerKey: ownerKey,
      title: title,
      lastActivity: at,
    );
    notifyListeners();
    _persist();
  }

  /// A thread the user forked from a message (`thread_fork`): listed under
  /// the agent that owns [sourceKey], like a chat an automation made.
  void addFork({
    required String key,
    required String sourceKey,
    required String title,
    DateTime? now,
  }) {
    if (key.isEmpty) return;
    final String ownerKey =
        _byKey[sourceKey]?.ownerKey ?? ownerOf(sourceKey) ?? sourceKey;
    _byKey[key] = AgentsDerivedThread(
      key: key,
      ownerKey: ownerKey,
      title: title,
      lastActivity: now ?? DateTime.now(),
    );
    notifyListeners();
    _persist();
  }

  /// Test seam.
  @visibleForTesting
  void reset() {
    _byKey.clear();
    _loaded = false;
  }
}
