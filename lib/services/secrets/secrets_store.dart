// lib/services/secrets/secrets_store.dart
//
// The device copy of the user's secret set (docs/WIRE_CONTRACT.md, "Secrets").
// One record in secure storage holds every name -> value pair and a revision
// counter. Nothing here ever goes to SharedPreferences, a log, or the UI: the
// pages only read [SecretsSet.names]; the values leave this store in exactly
// two directions, the encrypted Supabase mirror ([SecretsSync]) and the sealed
// `secrets` frame to the host ([SecretsStore.forwardPayload]).

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore, FlutterSecureKeyValueStore;

/// A snapshot of the set: the values and the revision they belong to.
@immutable
class SecretsSet {
  const SecretsSet({this.values = const <String, String>{}, this.revision = 0});

  final Map<String, String> values;

  /// Bumped on every local write. Informational on the host (the last frame
  /// wins there); it lets a reader tell two snapshots apart.
  final int revision;

  List<String> get names => values.keys.toList()..sort();
  bool get isEmpty => values.isEmpty;
  bool has(String name) => values.containsKey(name);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'revision': revision,
    'values': values,
  };

  static SecretsSet fromJson(Map<String, dynamic> json) {
    final raw = json['values'];
    final values = <String, String>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final name = entry.key.toString();
        final value = entry.value;
        if (SecretsStore.validName(name) &&
            value is String &&
            value.isNotEmpty) {
          values[name] = value;
        }
      }
    }
    final rev = json['revision'];
    return SecretsSet(
      values: values,
      revision: rev is int ? rev : (rev is num ? rev.toInt() : 0),
    );
  }
}

class SecretsStore {
  SecretsStore({CoworkSecureKeyValueStore? backend})
    : _backend = backend ?? const FlutterSecureKeyValueStore();

  /// The one secure-storage key holding the whole set.
  static const String storageKey = 'cowork_secrets_v1';

  /// Environment-variable name shape; the host drops anything else.
  static final RegExp _nameShape = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$');

  /// Values shorter than this are stored and injected like any other but are
  /// NOT masked in the agent's outputs (too short to be a real key, too likely
  /// to collide with ordinary text). The settings page says so.
  static const int redactMinLength = 8;

  final CoworkSecureKeyValueStore _backend;

  static bool validName(String name) => _nameShape.hasMatch(name);

  /// Every stored secret. Never throws: a corrupt record reads as empty.
  Future<SecretsSet> load() async {
    try {
      final raw = await _backend.read(storageKey);
      if (raw == null || raw.isEmpty) return const SecretsSet();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const SecretsSet();
      return SecretsSet.fromJson(Map<String, dynamic>.from(decoded));
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ [Secrets] Could not read the set: $e');
      return const SecretsSet();
    }
  }

  Future<void> _save(SecretsSet set) async {
    if (set.isEmpty && set.revision == 0) {
      await _backend.delete(storageKey);
      return;
    }
    await _backend.write(storageKey, jsonEncode(set.toJson()));
  }

  /// Replace the whole set (a mirror pull, or the dialog's batch). Names with
  /// a bad shape and empty values are dropped. Returns the new snapshot.
  Future<SecretsSet> replaceAll(Map<String, String> values) async {
    final current = await load();
    final clean = <String, String>{
      for (final e in values.entries)
        if (validName(e.key) && e.value.isNotEmpty) e.key: e.value,
    };
    final next = SecretsSet(values: clean, revision: current.revision + 1);
    await _save(next);
    return next;
  }

  /// Set one or more values, keeping the rest. An empty value for a name
  /// leaves that name alone (the dialog's "already set, left blank").
  Future<SecretsSet> setMany(Map<String, String> values) async {
    final current = await load();
    final merged = Map<String, String>.of(current.values);
    var changed = false;
    for (final e in values.entries) {
      if (!validName(e.key) || e.value.isEmpty) continue;
      if (merged[e.key] == e.value) continue;
      merged[e.key] = e.value;
      changed = true;
    }
    if (!changed) return current;
    final next = SecretsSet(values: merged, revision: current.revision + 1);
    await _save(next);
    return next;
  }

  Future<SecretsSet> set(String name, String value) =>
      setMany(<String, String>{name: value});

  Future<SecretsSet> remove(String name) async {
    final current = await load();
    if (!current.has(name)) return current;
    final merged = Map<String, String>.of(current.values)..remove(name);
    final next = SecretsSet(values: merged, revision: current.revision + 1);
    await _save(next);
    return next;
  }

  Future<void> clear() async {
    await _backend.delete(storageKey);
  }

  /// The `secrets` frame for the host: the WHOLE set, every time
  /// (docs/WIRE_CONTRACT.md). [requestId] ties it to a `secret_request`.
  static Map<String, dynamic> forwardPayload(
    SecretsSet set, {
    String? requestId,
  }) => <String, dynamic>{
    'type': 'secrets',
    'entries': <Map<String, String>>[
      for (final name in set.names)
        <String, String>{'name': name, 'value': set.values[name]!},
    ],
    'revision': set.revision,
    if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
  };
}
