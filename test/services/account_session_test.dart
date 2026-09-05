import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Session, User;

import 'package:cowork/services/account_session.dart';

/// A JWT whose only claim that matters is `exp` (gotrue reads it unverified).
String _jwt({required int exp, String sub = 'user-1'}) {
  String part(Map<String, Object> claims) =>
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${part({'sub': sub, 'exp': exp, 'iat': exp - 3600})}.sig';
}

Session _session({required int exp, String refresh = 'r1'}) {
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

void main() {
  const int nowSeconds = 1_800_000_000;
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(nowSeconds * 1000);

  group('SupabaseAccountSession.refresh', () {
    test('answers with the current pair while the access token is fresh', () async {
      int refreshCalls = 0;
      final source = SupabaseAccountSession(
        currentSession: () => _session(exp: nowSeconds + 20 * 60),
        refreshSession: () async {
          refreshCalls++;
          return _session(exp: nowSeconds + 3600, refresh: 'r2');
        },
        restoreSession: (_, _) async => fail('restore must not run'),
        now: now,
      );

      final session = await source.refresh();

      expect(refreshCalls, 0, reason: 'a fresh token is never spent');
      expect(session?.refreshToken, 'r1');
      expect(session?.expiresAt, nowSeconds + 20 * 60);
    });

    test('refreshes when the access token is about to lapse', () async {
      int refreshCalls = 0;
      Session current = _session(exp: nowSeconds + 45);
      final source = SupabaseAccountSession(
        currentSession: () => current,
        refreshSession: () async {
          refreshCalls++;
          current = _session(exp: nowSeconds + 3600, refresh: 'r2');
          return current;
        },
        now: now,
      );

      final session = await source.refresh();

      expect(refreshCalls, 1);
      expect(session?.refreshToken, 'r2');
      expect(session?.expiresAt, nowSeconds + 3600);
    });

    test('refreshes when the access token is already expired', () async {
      int refreshCalls = 0;
      final source = SupabaseAccountSession(
        currentSession: () => _session(exp: nowSeconds - 5),
        refreshSession: () async {
          refreshCalls++;
          return _session(exp: nowSeconds + 3600, refresh: 'r2');
        },
        now: now,
      );

      expect((await source.refresh())?.refreshToken, 'r2');
      expect(refreshCalls, 1);
    });

    test('restores the still-valid pair when the refresh is rejected', () async {
      // gotrue wipes the local session on a rejected refresh; the source must
      // put the (still valid) pair back instead of reporting "signed out".
      Session? current = _session(exp: nowSeconds + 40);
      final restored = <(String, String)>[];
      final source = SupabaseAccountSession(
        currentSession: () => current,
        refreshSession: () async {
          current = null; // what gotrue does on a non-retryable error
          return null;
        },
        restoreSession: (refresh, access) async {
          restored.add((refresh, access));
          current = _session(exp: nowSeconds + 40);
          return current;
        },
        now: now,
      );

      final session = await source.refresh();

      expect(restored, hasLength(1));
      expect(restored.single.$1, 'r1');
      expect(restored.single.$2, _jwt(exp: nowSeconds + 40));
      expect(session?.accessToken, _jwt(exp: nowSeconds + 40));
      expect(current, isNotNull, reason: 'the user stays signed in');
    });

    test('restores when the refresh throws instead of returning null', () async {
      Session? current = _session(exp: nowSeconds + 40);
      int restores = 0;
      final source = SupabaseAccountSession(
        currentSession: () => current,
        refreshSession: () async {
          current = null;
          throw StateError('refresh_token_not_found');
        },
        restoreSession: (_, _) async {
          restores++;
          current = _session(exp: nowSeconds + 40);
          return current;
        },
        now: now,
      );

      expect(await source.refresh(), isNotNull);
      expect(restores, 1);
    });

    test('gives up when the rejected pair is expired too', () async {
      Session? current = _session(exp: nowSeconds - 5);
      final source = SupabaseAccountSession(
        currentSession: () => current,
        refreshSession: () async {
          current = null;
          return null;
        },
        restoreSession: (_, _) async => fail('nothing left to restore'),
        now: now,
      );

      expect(await source.refresh(), isNull);
    });

    test('gives up when the restore is rejected as well', () async {
      Session? current = _session(exp: nowSeconds + 40);
      final source = SupabaseAccountSession(
        currentSession: () => current,
        refreshSession: () async {
          current = null;
          return null;
        },
        restoreSession: (_, _) async => throw StateError('session_not_found'),
        now: now,
      );

      expect(await source.refresh(), isNull);
    });

    test('does not restore when gotrue kept the session', () async {
      // A transient (network) failure: gotrue keeps the session, the refresh
      // helper returns it, and no restore round-trip is made.
      final kept = _session(exp: nowSeconds + 40);
      final source = SupabaseAccountSession(
        currentSession: () => kept,
        refreshSession: () async => kept,
        restoreSession: (_, _) async => fail('session was never wiped'),
        now: now,
      );

      expect((await source.refresh())?.refreshToken, 'r1');
    });

    test('returns null when signed out', () async {
      final source = SupabaseAccountSession(
        currentSession: () => null,
        refreshSession: () async => fail('nothing to refresh'),
        now: now,
      );

      expect(await source.refresh(), isNull);
      expect(source.current(), isNull);
    });
  });

  group('SupabaseAccountSession.needsRefresh', () {
    final source = SupabaseAccountSession(now: now);

    test('is due inside the headroom and past expiry', () {
      expect(source.needsRefresh(_session(exp: nowSeconds + 60)), isTrue);
      expect(source.needsRefresh(_session(exp: nowSeconds + 1)), isTrue);
      expect(source.needsRefresh(_session(exp: nowSeconds - 100)), isTrue);
    });

    test('is not due with more than the headroom left', () {
      expect(source.needsRefresh(_session(exp: nowSeconds + 61)), isFalse);
      expect(source.needsRefresh(_session(exp: nowSeconds + 3600)), isFalse);
    });

    test('is due when the expiry cannot be read', () {
      final opaque = Session(
        accessToken: 'not-a-jwt',
        refreshToken: 'r1',
        tokenType: 'bearer',
        user: const User(
          id: 'user-1',
          appMetadata: {},
          userMetadata: {},
          aud: 'authenticated',
          createdAt: '2025-11-22T02:01:50Z',
        ),
      );
      expect(source.needsRefresh(opaque), isTrue);
    });
  });
}
