import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/secrets/secrets_service.dart';
import 'package:chuk_chat/services/secrets/secrets_store.dart';
import 'package:chuk_chat/services/secrets/secrets_sync.dart';

class _Memory implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// A mirror that records what it was asked to do and can pre-seed a pull.
class _Mirror implements SecretsMirror {
  _Mirror({this.seed});

  Map<String, String>? seed;
  final List<(String, String)> saved = <(String, String)>[];
  final List<String> deleted = <String>[];

  @override
  Future<void> save(String name, String value) async => saved.add((name, value));

  @override
  Future<void> delete(String name) async => deleted.add(name);

  @override
  Future<Map<String, String>?> load() async => seed;
}

/// Every frame handed to the "host": `(values, revision, requestId)`.
List<(Map<String, String>, int, String?)> _sink(SecretsService Function() _) =>
    <(Map<String, String>, int, String?)>[];


/// Records with a Map inside compare by identity; flatten to compare by value.
List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs) =>
    <(String, int, String?)>[
      for (final x in xs) (jsonEncode(SplayTreeMap<String, String>.of(x.$1)), x.$2, x.$3),
    ];

String _j(Map<String, String> m) => jsonEncode(SplayTreeMap<String, String>.of(m));

void main() {
  late List<(Map<String, String>, int, String?)> sent;
  late _Mirror mirror;

  SecretsService boot({Map<String, String>? mirrored, _Memory? backend}) {
    sent = _sink(() => SecretsService.instance);
    mirror = _Mirror(seed: mirrored);
    return SecretsService.resetForTest(
      store: SecretsStore(backend: backend ?? _Memory()),
      mirror: mirror,
      hostSink: (set, {requestId}) async =>
          sent.add((Map<String, String>.of(set.values), set.revision, requestId)),
    );
  }

  test('set: local, mirror row, whole set to the host; names only in the UI',
      () async {
    final service = boot();
    await service.set('PEXELS_API_KEY', 'pexels-0123456789');

    expect(service.names.value, ['PEXELS_API_KEY']);
    expect(mirror.saved, [('PEXELS_API_KEY', 'pexels-0123456789')]);
    expect(_flat(sent), [
      (_j({'PEXELS_API_KEY': 'pexels-0123456789'}), 1, null),
    ]);
  });

  test('remove: mirror delete and the shrunken set to the host', () async {
    final service = boot();
    await service.set('A', 'aaaaaaaaaa');
    await service.set('B', 'bbbbbbbbbb');
    await service.remove('A');

    expect(service.names.value, ['B']);
    expect(mirror.deleted, ['A']);
    expect(_flat(sent).last, (_j({'B': 'bbbbbbbbbb'}), 3, null));
  });

  test('setMany with a request id answers the request with the whole set',
      () async {
    final service = boot();
    await service.set('OLD', 'oooooooooo');
    await service.setMany({'NEW': 'nnnnnnnnnn', 'OLD': ''}, requestId: 'r-1');

    expect(
      _flat(sent).last,
      (_j({'NEW': 'nnnnnnnnnn', 'OLD': 'oooooooooo'}), 2, 'r-1'),
    );
    // Only the changed row went to the mirror.
    expect(mirror.saved.map((e) => e.$1), ['OLD', 'NEW']);
  });

  test('answerUnchanged sends the same set with the request id (a cancel)',
      () async {
    final service = boot();
    await service.set('A', 'aaaaaaaaaa');
    await service.answerUnchanged('r-2');
    expect(_flat(sent).last, (_j({'A': 'aaaaaaaaaa'}), 1, 'r-2'));
  });

  test('a fresh install adopts the mirror once and forwards it after a '
      'provision', () async {
    final service = boot(mirrored: {'FROM_CLOUD': 'cloud-value-1'});
    await service.forwardToHost();

    expect(service.names.value, ['FROM_CLOUD']);
    expect(_flat(sent), [
      (_j({'FROM_CLOUD': 'cloud-value-1'}), 1, null),
    ]);
    // Adopting is not a change: nothing is pushed back to the mirror.
    expect(mirror.saved, isEmpty);
  });

  test('a local set wins over the mirror', () async {
    final backend = _Memory();
    await SecretsStore(backend: backend).set('LOCAL', 'local-value-1');
    final service = boot(mirrored: {'FROM_CLOUD': 'cloud-value-1'}, backend: backend);
    await service.load();
    expect(service.names.value, ['LOCAL']);
  });

  test('a failing host sink never throws out of the service', () async {
    mirror = _Mirror();
    final service = SecretsService.resetForTest(
      store: SecretsStore(backend: _Memory()),
      mirror: mirror,
      hostSink: (set, {requestId}) async => throw StateError('Not paired'),
    );
    await service.set('A', 'aaaaaaaaaa');
    expect(service.names.value, ['A']);
    expect(service.forwarded.single.$2, ['A']);
  });
}
