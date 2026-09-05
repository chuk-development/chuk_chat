/// The app-wide owner of the user's secret set (docs/WIRE_CONTRACT.md,
/// "Secrets"): local store + encrypted mirror + the sealed frame to the host.
///
/// Three writers, one path:
///
///  * the settings page (add / change / delete a key),
///  * the thread view's `secret_request` card (the model asked by name),
///  * the mirror on a fresh install (adopted once, when the local set is empty).
///
/// After every change the WHOLE set goes to the host as one `secrets` frame
/// through the bound relay controller, and the changed rows go to the mirror.
/// After every provision the relay client asks this service to forward the set
/// once more, so a host that restarted holds what the device holds.
///
/// The UI only ever sees [names]; the values stay inside this service, the
/// store, the mirror and the sealed frame.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/secrets/secrets_store.dart';
import 'package:cowork/services/secrets/secrets_sync.dart';

/// Where a `secrets` frame goes. Defaults to the link's bound controller.
typedef SecretsHostSink = Future<void> Function(
  SecretsSet set, {
  String? requestId,
});

class SecretsService {
  SecretsService._({
    SecretsStore? store,
    SecretsMirror? mirror,
    SecretsHostSink? hostSink,
  })  : _store = store ?? SecretsStore(),
        _mirror = mirror ?? const SecretsSync(),
        _hostSink = hostSink ?? _defaultHostSink;

  static SecretsService _instance = SecretsService._();
  static SecretsService get instance => _instance;

  /// Test seam: a fresh service over injected parts. Also resets the
  /// notifier so a test starts from an empty list.
  @visibleForTesting
  static SecretsService resetForTest({
    SecretsStore? store,
    SecretsMirror? mirror,
    SecretsHostSink? hostSink,
  }) {
    _instance = SecretsService._(store: store, mirror: mirror, hostSink: hostSink);
    return _instance;
  }

  final SecretsStore _store;
  final SecretsMirror _mirror;
  final SecretsHostSink _hostSink;

  /// The names that are set, sorted. What every page renders.
  final ValueNotifier<List<String>> names = ValueNotifier<List<String>>(const <String>[]);

  int _revision = 0;
  int get revision => _revision;

  Future<void>? _loading;
  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// Every `secrets` frame handed to the host, for diagnostics: `(revision,
  /// names, requestId)`. Never a value.
  @visibleForTesting
  final List<(int, List<String>, String?)> forwarded = <(int, List<String>, String?)>[];

  static Future<void> _defaultHostSink(SecretsSet set, {String? requestId}) async {
    final controller = CoworkRelayLink.instance.controller.value;
    if (controller == null) return;
    await controller.sendSecrets(
      values: set.values,
      revision: set.revision,
      requestId: requestId,
    );
  }

  /// Read the local set; on an empty local set, pull the mirror once and adopt
  /// it (a reinstall). Idempotent and single-flight.
  Future<void> load() {
    return _loading ??= _loadOnce();
  }

  Future<void> _loadOnce() async {
    var set = await _store.load();
    if (set.isEmpty) {
      final mirrored = await _mirror.load();
      if (mirrored != null && mirrored.isNotEmpty) {
        set = await _store.replaceAll(mirrored);
      }
    }
    _publish(set);
    _loaded = true;
  }

  void _publish(SecretsSet set) {
    _revision = set.revision;
    final next = set.names;
    if (!listEquals(names.value, next)) names.value = next;
  }

  /// Set (or change) one key. Empty [value] is ignored.
  Future<void> set(String name, String value) =>
      setMany(<String, String>{name: value});

  /// Set several keys at once (the dialog's answer). [requestId] ties the
  /// resulting frame to the `secret_request` it answers; the frame goes out
  /// even when nothing changed, because the host is waiting for it.
  Future<void> setMany(Map<String, String> values, {String? requestId}) async {
    await load();
    final before = await _store.load();
    final after = await _store.setMany(values);
    _publish(after);
    for (final e in values.entries) {
      if (after.has(e.key) && before.values[e.key] != after.values[e.key]) {
        unawaited(_mirror.save(e.key, after.values[e.key]!));
      }
    }
    await _forward(after, requestId: requestId);
  }

  Future<void> remove(String name) async {
    await load();
    final after = await _store.remove(name);
    _publish(after);
    unawaited(_mirror.delete(name));
    await _forward(after);
  }

  /// The user dismissed a `secret_request` without entering anything: the
  /// host still needs a frame to end the wait, so send the unchanged set.
  Future<void> answerUnchanged(String requestId) async {
    await load();
    await _forward(await _store.load(), requestId: requestId);
  }

  /// Forward the current set to the host (after a provision). Loads first, so
  /// a fresh install never overwrites the host's set with an empty one before
  /// the mirror was consulted.
  Future<void> forwardToHost() async {
    await load();
    await _forward(await _store.load());
  }

  Future<void> _forward(SecretsSet set, {String? requestId}) async {
    forwarded.add((set.revision, set.names, requestId));
    try {
      await _hostSink(set, requestId: requestId);
    } catch (e) {
      // Not paired, socket gone: the next provision forwards the set again.
      if (kDebugMode) debugPrint('⚠️ [Secrets] forward skipped: $e');
    }
  }
}
