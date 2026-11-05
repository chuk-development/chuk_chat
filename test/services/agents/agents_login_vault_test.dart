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
    expect(host.frames.single, <String, dynamic>{'type': 'login_vault_list'});
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
    expect(host.frames.single, <String, dynamic>{
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
    expect(host.frames.single, <String, dynamic>{
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
