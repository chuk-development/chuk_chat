import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/supabase_service.dart';

Session _sessionExpiringIn(Duration remaining) {
  final int expiresAt =
      (DateTime.now().add(remaining).millisecondsSinceEpoch / 1000).round();
  final session = Session(
    accessToken: 'access-token',
    tokenType: 'bearer',
    refreshToken: 'refresh-token',
    expiresIn: remaining.inSeconds,
    user: User(
      id: 'user-1',
      appMetadata: const <String, dynamic>{},
      userMetadata: const <String, dynamic>{},
      aud: 'authenticated',
      createdAt: DateTime.now().toIso8601String(),
    ),
  );
  // `expiresAt` is normally decoded from the JWT; the token here is a stub,
  // so the expiry is set directly.
  session.expiresAt = expiresAt;
  return session;
}

void main() {
  group('sessionNeedsRefresh', () {
    test('a token with an hour left is used as is', () {
      expect(
        SupabaseService.sessionNeedsRefresh(
          _sessionExpiringIn(const Duration(hours: 1)),
        ),
        isFalse,
      );
    });

    test('a token inside the leeway is renewed', () {
      expect(
        SupabaseService.sessionNeedsRefresh(
          _sessionExpiringIn(const Duration(minutes: 5)),
        ),
        isTrue,
      );
    });

    test('an expired token is renewed', () {
      expect(
        SupabaseService.sessionNeedsRefresh(
          _sessionExpiringIn(const Duration(minutes: -1)),
        ),
        isTrue,
      );
    });
  });
}
