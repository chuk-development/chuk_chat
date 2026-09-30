import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/session_manager_service.dart';

void main() {
  group('SessionManagerService.isSignOutEvent', () {
    test('initialSession without a session while a session is stashed is '
        'not a sign-out', () {
      expect(
        SessionManagerService.isSignOutEvent(
          const AuthState(AuthChangeEvent.initialSession, null),
          sessionStashed: true,
        ),
        isFalse,
      );
    });

    test('initialSession without a session and no stash is a sign-out', () {
      expect(
        SessionManagerService.isSignOutEvent(
          const AuthState(AuthChangeEvent.initialSession, null),
        ),
        isTrue,
      );
    });

    test('signedOut is a sign-out, stash or not', () {
      for (final stashed in [false, true]) {
        expect(
          SessionManagerService.isSignOutEvent(
            const AuthState(AuthChangeEvent.signedOut, null),
            sessionStashed: stashed,
          ),
          isTrue,
        );
      }
    });

    test('any other event without a session is a sign-out', () {
      expect(
        SessionManagerService.isSignOutEvent(
          const AuthState(AuthChangeEvent.tokenRefreshed, null),
          sessionStashed: true,
        ),
        isTrue,
      );
    });
  });
}
