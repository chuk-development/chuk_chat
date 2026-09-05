import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore;
import 'package:cowork/services/secrets/secrets_store.dart';

/// In-memory secure backend so the set round-trips with no platform channel.
class _Memory implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

void main() {
  test('an empty store reads as an empty set at revision 0', () async {
    final store = SecretsStore(backend: _Memory());
    final set = await store.load();
    expect(set.isEmpty, isTrue);
    expect(set.revision, 0);
  });

  test('set / setMany / remove bump the revision and keep the rest', () async {
    final backend = _Memory();
    final store = SecretsStore(backend: backend);

    var set = await store.set('PEXELS_API_KEY', 'pexels-0123456789');
    expect(set.names, ['PEXELS_API_KEY']);
    expect(set.revision, 1);

    set = await store.setMany({'B': 'bbbbbbbbbb', 'PEXELS_API_KEY': ''});
    expect(set.names, ['B', 'PEXELS_API_KEY']);
    expect(set.values['PEXELS_API_KEY'], 'pexels-0123456789'); // blank keeps
    expect(set.revision, 2);

    // Same value again: no write, no bump.
    set = await store.set('B', 'bbbbbbbbbb');
    expect(set.revision, 2);

    set = await store.remove('B');
    expect(set.names, ['PEXELS_API_KEY']);
    expect(set.revision, 3);

    // The record is in secure storage only, under the one key.
    expect(backend.map.keys, [SecretsStore.storageKey]);
    final decoded = jsonDecode(backend.map[SecretsStore.storageKey]!);
    expect(decoded['revision'], 3);
    expect(decoded['values'], {'PEXELS_API_KEY': 'pexels-0123456789'});
  });

  test('bad names and empty values are dropped', () async {
    final store = SecretsStore(backend: _Memory());
    final set = await store.replaceAll({
      'OK_NAME': 'value-1234',
      'bad-name': 'x',
      '9start': 'y',
      'EMPTY': '',
    });
    expect(set.names, ['OK_NAME']);
    expect(SecretsStore.validName('A_1'), isTrue);
    expect(SecretsStore.validName('a-b'), isFalse);
  });

  test('replaceAll swaps the whole set', () async {
    final store = SecretsStore(backend: _Memory());
    await store.set('A', 'aaaaaaaaaa');
    final set = await store.replaceAll({'B': 'bbbbbbbbbb'});
    expect(set.names, ['B']);
    expect(set.revision, 2);
  });

  test('the forward payload is the whole set, sorted, with the request id',
      () {
    const set = SecretsSet(
      values: {'Z_KEY': 'zzzzzzzzzz', 'A_KEY': 'aaaaaaaaaa'},
      revision: 7,
    );
    expect(SecretsStore.forwardPayload(set, requestId: 'r1'), {
      'type': 'secrets',
      'entries': [
        {'name': 'A_KEY', 'value': 'aaaaaaaaaa'},
        {'name': 'Z_KEY', 'value': 'zzzzzzzzzz'},
      ],
      'revision': 7,
      'request_id': 'r1',
    });
    expect(SecretsStore.forwardPayload(set).containsKey('request_id'), isFalse);
  });

  test('a corrupt record reads as empty, never throws', () async {
    final backend = _Memory()..map[SecretsStore.storageKey] = '{not json';
    final set = await SecretsStore(backend: backend).load();
    expect(set.isEmpty, isTrue);
  });
}
