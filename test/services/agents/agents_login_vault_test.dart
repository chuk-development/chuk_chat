import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_login_vault.dart';
import 'package:chuk_chat/services/agents/agents_reply_frames.dart';

/// A host that answers each frame with [reply] (or nothing) and records it.
class _Host {
  _Host(this.bus);

  final AgentsReplyFrames bus;
  Map<String, dynamic> Function(Map<String, dynamic> frame)? reply;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  Future<void> send(Map<String, dynamic> frame) async {
    frames.add(frame);
    final answer = reply?.call(frame);
    if (answer != null) {
      Future<void>.microtask(() => bus.add(answer));
    }
  }
}

Map<String, dynamic> _entry({bool totp = false}) => <String, dynamic>{
  'id': '3f9c0a1b2c3d4e5f',
  'origin': 'https://github.com',
  'username': 'octo@example.com',
  'label': 'work',
  'has_totp': totp,
  'created_at': 1762300000000,
  'last_used_at': null,
};

/// [frame] without its `request_id` (a fresh one per request).
Map<String, dynamic> _bare(Map<String, dynamic> frame) {
  expect(frame['request_id'], isA<String>());
  return Map<String, dynamic>.of(frame)..remove('request_id');
}

void main() {
  late AgentsReplyFrames bus;
  late _Host host;
  late AgentsLoginVault vault;

  setUp(() {
    bus = AgentsReplyFrames();
    host = _Host(bus);
    vault = AgentsLoginVault(
      send: host.send,
      replies: bus,
      timeout: const Duration(milliseconds: 200),
    );
  });

  group('loginOriginOf', () {
    test('keeps scheme, host and a non-default port, in lower case', () {
      expect(
        loginOriginOf('https://GitHub.com/login?x=1'),
        'https://github.com',
      );
      expect(loginOriginOf('github.com/login'), 'https://github.com');
      expect(
        loginOriginOf('https://a.example:8443/p'),
        'https://a.example:8443',
      );
    });

    test('drops the default ports', () {
      expect(loginOriginOf('https://github.com:443/'), 'https://github.com');
      expect(loginOriginOf('http://localhost:80/x'), 'http://localhost');
    });

    test('http only for localhost, 127.0.0.1 and ::1', () {
      expect(loginOriginOf('http://localhost:3000'), 'http://localhost:3000');
      expect(loginOriginOf('http://127.0.0.1:8080'), 'http://127.0.0.1:8080');
      expect(loginOriginOf('http://[::1]:5000'), 'http://[::1]:5000');
      expect(loginOriginOf('http://github.com'), isNull);
      expect(loginOriginOf('ftp://github.com'), isNull);
      expect(loginOriginOf(''), isNull);
    });
  });

  test('list sends login_vault_list and keeps the public entries', () async {
    host.reply = (_) => <String, dynamic>{
      'type': 'login_vault',
      'entries': <Object>[_entry(totp: true)],
    };
    final reply = await vault.refresh();
    expect(_bare(host.frames.single), <String, dynamic>{'type': 'login_vault_list'});
    expect(reply.ok, isTrue);
    expect(vault.loaded, isTrue);
    final e = vault.entries.single;
    expect(e.origin, 'https://github.com');
    expect(e.username, 'octo@example.com');
    expect(e.label, 'work');
    expect(e.hasTotp, isTrue);
    expect(e.lastUsedAt, isNull);
    expect(e.createdAt, DateTime.fromMillisecondsSinceEpoch(1762300000000));
  });

  test('set carries password and totp in the frame only', () async {
    host.reply = (_) => <String, dynamic>{
      'type': 'login_vault',
      'entries': <Object>[_entry(totp: true)],
      'saved': _entry(totp: true),
    };
    final reply = await vault.save(
      origin: 'https://github.com',
      username: 'octo@example.com',
      password: 'hunter2-secret',
      totpSecret: 'JBSWY3DPEHPK3PXP',
      label: 'work',
    );
    expect(_bare(host.frames.single), <String, dynamic>{
      'type': 'login_vault_set',
      'origin': 'https://github.com',
      'username': 'octo@example.com',
      'password': 'hunter2-secret',
      'totp_secret': 'JBSWY3DPEHPK3PXP',
      'label': 'work',
    });
    expect(reply.saved?.id, '3f9c0a1b2c3d4e5f');
    // Nothing the app keeps holds the secret.
    final kept = jsonEncode(<Object?>[
      for (final e in vault.entries)
        <Object?>[e.id, e.origin, e.username, e.label, e.hasTotp],
    ]);
    expect(kept, isNot(contains('hunter2')));
    expect(kept, isNot(contains('JBSWY3')));
  });

  test('an edit without a new key leaves totp_secret out', () async {
    host.reply = (_) => <String, dynamic>{'type': 'login_vault', 'entries': []};
    await vault.save(
      origin: 'https://github.com',
      username: 'octo',
      password: 'p',
      totpSecret: '',
    );
    expect(host.frames.single.containsKey('totp_secret'), isFalse);
    expect(host.frames.single.containsKey('label'), isFalse);
  });

  test('removing the key sends totp_secret null', () async {
    host.reply = (_) => <String, dynamic>{'type': 'login_vault', 'entries': []};
    await vault.save(
      origin: 'https://github.com',
      username: 'octo',
      password: 'p',
      removeTotp: true,
    );
    expect(host.frames.single.containsKey('totp_secret'), isTrue);
    expect(host.frames.single['totp_secret'], isNull);
  });

  test('delete sends the id and reads deleted', () async {
    host.reply = (_) => <String, dynamic>{
      'type': 'login_vault',
      'entries': <Object>[],
      'deleted': 'abc',
    };
    final reply = await vault.delete('abc');
    expect(_bare(host.frames.single), <String, dynamic>{
      'type': 'login_vault_delete',
      'id': 'abc',
    });
    expect(reply.deleted, 'abc');
    expect(vault.entries, isEmpty);
  });

  test('a host error is passed on and the list still replaces', () async {
    host.reply = (_) => <String, dynamic>{
      'type': 'login_vault',
      'entries': <Object>[_entry()],
      'error': 'password is required',
    };
    final reply = await vault.save(
      origin: 'https://github.com',
      username: 'octo',
      password: '',
    );
    expect(reply.ok, isFalse);
    expect(reply.error, 'password is required');
    expect(vault.entries, hasLength(1));
  });

  test('no reply and no link become the marker errors', () async {
    final timeout = await vault.refresh();
    expect(timeout.error, kLoginVaultNoReply);
    final offline = AgentsLoginVault(
      send: (_) async => throw const AgentsNotConnected(),
      replies: bus,
    );
    expect((await offline.refresh()).error, kLoginVaultNotConnected);
  });

  group('reply matching (review of b8e3343c, finding 1)', () {
    test('a list reply with another request_id never answers a save', () async {
      // The host answers the save with a refusal; before that, the reply to
      // a refresh sent earlier (another id) lands.
      final save = vault.save(
        origin: 'https://github.com',
        username: 'octo',
        password: 'pw',
      );
      await Future<void>.delayed(Duration.zero);
      final String id = host.frames.single['request_id'] as String;
      expect(id, isNotEmpty);
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[_entry()],
        'request_id': 'lv-someone-else',
      });
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[],
        'error': 'the host refused it',
        'request_id': id,
      });
      final reply = await save;
      expect(reply.ok, isFalse);
      expect(reply.error, 'the host refused it');
    });

    test('an old host: a bare list does not count as saved or deleted', () async {
      final save = vault.save(
        origin: 'https://github.com',
        username: 'octo',
        password: 'pw',
      );
      await Future<void>.delayed(Duration.zero);
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[_entry()],
      });
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[],
        'error': 'password is required',
      });
      expect((await save).error, 'password is required');

      final delete = vault.delete('3f9c0a1b2c3d4e5f');
      await Future<void>.delayed(Duration.zero);
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[_entry()],
      });
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[],
        'deleted': '3f9c0a1b2c3d4e5f',
      });
      final deleted = await delete;
      expect(deleted.ok, isTrue);
      expect(deleted.deleted, '3f9c0a1b2c3d4e5f');
    });

    test('an old host: requests go out one at a time', () async {
      final refresh = vault.refresh();
      final save = vault.save(
        origin: 'https://github.com',
        username: 'octo',
        password: 'pw',
      );
      await Future<void>.delayed(Duration.zero);
      expect(host.frames, hasLength(1));
      expect(host.frames.single['type'], 'login_vault_list');
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[_entry()],
      });
      await refresh;
      await Future<void>.delayed(Duration.zero);
      expect(host.frames, hasLength(2));
      expect(host.frames.last['type'], 'login_vault_set');
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[_entry()],
        'saved': _entry(),
      });
      expect((await save).saved?.id, '3f9c0a1b2c3d4e5f');
    });

    test('a host that echoes ids lets requests overlap', () async {
      host.reply = (Map<String, dynamic> f) => <String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[_entry()],
        if (f['type'] == 'login_vault_set') 'saved': _entry(),
        'request_id': f['request_id'],
      };
      await vault.refresh();
      host.reply = null;
      final a = vault.refresh();
      final b = vault.delete('3f9c0a1b2c3d4e5f');
      await Future<void>.delayed(Duration.zero);
      expect(host.frames.skip(1), hasLength(2));
      final ids = <String>[
        for (final f in host.frames.skip(1)) f['request_id'] as String,
      ];
      expect(ids.toSet(), hasLength(2));
      // Answered out of order: each request still gets its own reply.
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[],
        'deleted': '3f9c0a1b2c3d4e5f',
        'request_id': ids[1],
      });
      bus.add(<String, dynamic>{
        'type': 'login_vault',
        'entries': <Object>[],
        'request_id': ids[0],
      });
      expect((await b).deleted, '3f9c0a1b2c3d4e5f');
      expect((await a).ok, isTrue);
    });
  });

  test('a malformed entry is dropped', () {
    final reply = AgentsLoginVaultReply.fromPayload(<String, dynamic>{
      'type': 'login_vault',
      'entries': <Object>[
        <String, dynamic>{'origin': 'https://x.dev'},
        _entry(),
      ],
    });
    expect(reply.entries, hasLength(1));
  });
}
