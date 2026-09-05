import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Session, User;

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/session_recovery.dart';

String _jwt({required int exp, String sub = 'user-1'}) {
  String part(Map<String, Object> claims) =>
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${part({'sub': sub, 'exp': exp, 'iat': exp - 3600})}.sig';
}

Session _session({required int exp, required String refresh}) {
  return Session(
    accessToken: _jwt(exp: exp),
    refreshToken: refresh,
    tokenType: 'bearer',
    user: const User(
      id: 'user-1',
      appMetadata: {},
      userMetadata: {},
      aud: 'authenticated',
      createdAt: '2025-11-22T02:01:50Z',
    ),
  );
}

/// A host on the other end of the recovery link, scripted per test.
class _FakeLink implements RecoveryLink {
  AccountSessionSource? source;
  Future<AccountSession?> Function(String refreshToken)? adopter;
  bool attachFails = false;
  bool disposed = false;
  final List<AccountSession> provisioned = [];
  Future<void> Function(_FakeLink link)? onProvision;

  @override
  Future<void> attach({
    required AccountSessionSource sessionSource,
    required Future<AccountSession?> Function(String refreshToken) adopter,
  }) async {
    if (attachFails) throw StateError('host unreachable');
    source = sessionSource;
    this.adopter = adopter;
  }

  @override
  Future<void> provision(AccountSession session) async {
    provisioned.add(session);
    await onProvision?.call(this);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  const int now = 1_800_000_000;
  const stash = SessionStash(
    accessToken: 'stale-access',
    refreshToken: 'r-stash',
    userId: 'user-1',
    expiresAt: now - 100,
  );

  /// gotrue stand-in: `/token` succeeds for the tokens in [live], the
  /// resulting session becomes current.
  ({
    Session? Function() current,
    Future<Session?> Function(String) exchange,
    List<String> exchanged,
  }) gotrue({Set<String> live = const {'r-stash', 'r-host'}}) {
    Session? current;
    final exchanged = <String>[];
    return (
      current: () => current,
      exchange: (String token) async {
        exchanged.add(token);
        if (!live.contains(token)) throw StateError('refresh_token_not_found');
        current = _session(exp: now + 3600, refresh: '$token-next');
        return current;
      },
      exchanged: exchanged,
    );
  }

  SessionRecovery recovery(_FakeLink? link, dynamic g) => SessionRecovery(
        stash: stash,
        link: link,
        currentSession: g.current,
        refreshFromToken: g.exchange,
        hostTimeout: const Duration(milliseconds: 300),
        adoptionGrace: const Duration(milliseconds: 300),
        pollInterval: const Duration(milliseconds: 10),
      );

  group('SessionRecovery.run', () {
    test('adopts the pair the host rotated and never spends its own', () async {
      final g = gotrue();
      final link = _FakeLink()
        ..onProvision = (link) async {
          // The host flushes `account_session_rotated` right after provision.
          await link.adopter!('r-host');
        };

      final result = await recovery(link, g).run();

      expect(result?.refreshToken, 'r-host-next');
      expect(g.exchanged, ['r-host']);
      expect(link.provisioned.single.accessToken, 'stale-access');
      expect(link.disposed, isTrue);
    });

    test('spends its own token when the host asks and has nothing newer',
        () async {
      final g = gotrue();
      AccountSession? answered;
      final link = _FakeLink()
        ..onProvision = (link) async {
          // The stale pair 401s at the host: `reprovision_request`.
          answered = await link.source!.refresh();
        };

      final result = await recovery(link, g).run();

      expect(g.exchanged, ['r-stash']);
      expect(answered?.refreshToken, 'r-stash-next');
      expect(result?.refreshToken, 'r-stash-next');
    });

    test('a reprovision during an adoption waits for it instead of spending',
        () async {
      final g = gotrue();
      AccountSession? answered;
      // Rotation and request arrive back to back (FIFO): the adopter has
      // started, the answer must wait for it, not spend the dead token.
      final link = _FakeLink()
        ..onProvision = (link) async {
          final adoption = link.adopter!('r-host');
          answered = await link.source!.refresh();
          await adoption;
        };

      final result = await recovery(link, g).run();

      expect(g.exchanged, ['r-host']);
      expect(answered?.refreshToken, 'r-host-next');
      expect(result?.refreshToken, 'r-host-next');
    });

    test('falls back to its own token when the host is unreachable', () async {
      final g = gotrue();
      final link = _FakeLink()..attachFails = true;

      final result = await recovery(link, g).run();

      expect(g.exchanged, ['r-stash']);
      expect(result?.refreshToken, 'r-stash-next');
      expect(link.disposed, isTrue);
    });

    test('falls back to its own token when the host stays silent', () async {
      final g = gotrue();
      final link = _FakeLink(); // attaches, says nothing

      final result = await recovery(link, g).run();

      expect(g.exchanged, ['r-stash']);
      expect(result, isNotNull);
    });

    test('spends its own token with no host paired', () async {
      final g = gotrue();

      final result = await recovery(null, g).run();

      expect(g.exchanged, ['r-stash']);
      expect(result?.refreshToken, 'r-stash-next');
    });

    test('gives up when both pairs are dead', () async {
      final g = gotrue(live: const {});
      final link = _FakeLink()
        ..onProvision = (link) async {
          await link.adopter!('r-host');
        };

      final result = await recovery(link, g).run();

      expect(result, isNull);
      // The rotation was reported: our own token is known dead, never sent.
      expect(g.exchanged, ['r-host']);
      expect(link.disposed, isTrue);
    });

    test('shows the host the stale pair until a live one exists', () async {
      final g = gotrue();
      AccountSession? before;
      AccountSession? after;
      final link = _FakeLink()
        ..onProvision = (link) async {
          before = link.source!.current();
          await link.adopter!('r-host');
          after = link.source!.current();
        };

      await recovery(link, g).run();

      expect(before?.accessToken, 'stale-access');
      expect(after?.refreshToken, 'r-host-next');
    });
  });

  group('SessionStash.setAsideExpiredSession', () {
    const key = 'sb-test-auth-token';
    DateTime clock() => DateTime.fromMillisecondsSinceEpoch(now * 1000);

    String persisted({required int exp, String refresh = 'r1'}) => jsonEncode({
          'access_token': _jwt(exp: exp),
          'refresh_token': refresh,
          'expires_at': exp,
          'token_type': 'bearer',
          'user': {'id': 'user-1'},
        });

    setUp(() => SessionStash.pending = null);

    test('sets an expired session aside and hides it from gotrue', () async {
      SharedPreferences.setMockInitialValues({
        key: persisted(exp: now - 10),
      });
      final prefs = await SharedPreferences.getInstance();

      final stash = await SessionStash.setAsideExpiredSession(
        prefs: prefs,
        persistedKey: key,
        now: clock,
      );

      expect(stash?.refreshToken, 'r1');
      expect(stash?.userId, 'user-1');
      expect(prefs.getString(key), isNull, reason: 'gotrue must not see it');
      expect(prefs.getString(SessionStash.prefsKey), isNotNull);
      expect(SessionStash.pending, same(stash));
    });

    test('sets a session inside the headroom aside too', () async {
      SharedPreferences.setMockInitialValues({
        key: persisted(exp: now + 45),
      });
      final prefs = await SharedPreferences.getInstance();

      final stash = await SessionStash.setAsideExpiredSession(
        prefs: prefs,
        persistedKey: key,
        now: clock,
      );

      expect(stash, isNotNull);
      expect(prefs.getString(key), isNull);
    });

    test('leaves a session with life left to gotrue', () async {
      final raw = persisted(exp: now + 3600);
      SharedPreferences.setMockInitialValues({key: raw});
      final prefs = await SharedPreferences.getInstance();

      final stash = await SessionStash.setAsideExpiredSession(
        prefs: prefs,
        persistedKey: key,
        now: clock,
      );

      expect(stash, isNull);
      expect(prefs.getString(key), raw);
      expect(SessionStash.pending, isNull);
    });

    test('does nothing when signed out', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      expect(
        await SessionStash.setAsideExpiredSession(
          prefs: prefs,
          persistedKey: key,
          now: clock,
        ),
        isNull,
      );
    });

    test('resumes a stash a crashed recovery left behind', () async {
      SharedPreferences.setMockInitialValues({
        SessionStash.prefsKey: jsonEncode(const SessionStash(
          accessToken: 'a',
          refreshToken: 'r-left',
          userId: 'user-1',
          expiresAt: now - 5,
        ).toJson()),
      });
      final prefs = await SharedPreferences.getInstance();

      final stash = await SessionStash.setAsideExpiredSession(
        prefs: prefs,
        persistedKey: key,
        now: clock,
      );

      expect(stash?.refreshToken, 'r-left');
    });

    test('drops a leftover stash once a real session exists again', () async {
      final raw = persisted(exp: now + 3600);
      SharedPreferences.setMockInitialValues({
        key: raw,
        SessionStash.prefsKey: jsonEncode(const SessionStash(
          accessToken: 'a',
          refreshToken: 'r-left',
          userId: 'user-1',
        ).toJson()),
      });
      final prefs = await SharedPreferences.getInstance();

      final stash = await SessionStash.setAsideExpiredSession(
        prefs: prefs,
        persistedKey: key,
        now: clock,
      );

      expect(stash, isNull);
      expect(prefs.getString(SessionStash.prefsKey), isNull);
      expect(prefs.getString(key), raw);
    });

    test('reads the expiry off the JWT when expires_at is missing', () {
      final stash = SessionStash.fromPersistedSession(jsonEncode({
        'access_token': _jwt(exp: now + 7),
        'refresh_token': 'r1',
        'user': {'id': 'user-1'},
      }));
      expect(stash?.expiresAt, now + 7);
    });

    test('derives the persisted key the way supabase_flutter does', () {
      expect(
        SessionStash.persistedSessionKey('https://abcdefgh.supabase.co'),
        'sb-abcdefgh-auth-token',
      );
    });
  });
}
