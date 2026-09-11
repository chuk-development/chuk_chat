import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/session_recovery.dart';
import 'package:cowork/widgets/auth_gate.dart';

String _jwt({required int exp}) {
  String part(Map<String, Object> claims) =>
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');
  return '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
      '${part({'sub': 'user-1', 'exp': exp, 'iat': exp - 3600})}.sig';
}

Session _session({String refresh = 'r1'}) => Session(
      accessToken: _jwt(exp: 1_800_000_000),
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

void main() {
  late StreamController<AuthState> auth;
  Session? current;
  final recoveries = <SessionStash>[];
  Future<AccountSession?> Function(SessionStash)? recover;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    auth = StreamController<AuthState>.broadcast();
    current = null;
    recoveries.clear();
    recover = null;
    SessionStash.pending = null;
    SessionRecovery.inFlight = null;
  });

  tearDown(() => auth.close());

  Widget gate({SessionStash? stash}) => MaterialApp(
        home: AuthGate(
          stash: stash,
          authChanges: auth.stream,
          currentSession: () => current,
          recover: (s) async {
            recoveries.add(s);
            return recover?.call(s);
          },
          buildShell: (_) => const Text('SHELL'),
          buildLogin: (_) => const Text('LOGIN'),
        ),
      );

  testWidgets('shows the login page when signed out with nothing to recover',
      (tester) async {
    await tester.pumpWidget(gate());
    expect(find.text('LOGIN'), findsOneWidget);
    expect(recoveries, isEmpty);
  });

  testWidgets('shows the shell with a session', (tester) async {
    current = _session();
    await tester.pumpWidget(gate());
    expect(find.text('SHELL'), findsOneWidget);
  });

  testWidgets('a set-aside session mounts the shell at once and recovers '
      'behind it', (tester) async {
    const stash = SessionStash(
      accessToken: 'a',
      refreshToken: 'r-stash',
      userId: 'user-1',
    );
    final done = Completer<AccountSession?>();
    recover = (_) => done.future;

    await tester.pumpWidget(gate(stash: stash));

    // A stashed session IS a signed-in user: the tokens are on this device and
    // only the live pair has to be fetched back. So the shell is up in the
    // first frame — the roster and the transcript are local — and nobody waits
    // behind a spinner for the host (bead cowork-91pn).
    expect(find.text('SHELL'), findsOneWidget);
    expect(find.text('Reconnecting to your host…'), findsNothing);
    expect(find.text('LOGIN'), findsNothing);
    // The recovery really did start, from the stashed pair.
    expect(recoveries.single.refreshToken, 'r-stash');
    // And it holds the device's one relay socket while it runs, so the shell's
    // own transport waits for it instead of displacing it.
    expect(SessionRecovery.inFlight, isNotNull);

    current = _session(refresh: 'r-host-next');
    done.complete(AccountSession.fromSupabase(current!));
    await tester.pump();
    await tester.pump();

    expect(find.text('SHELL'), findsOneWidget);
    expect(SessionRecovery.inFlight, isNull);
  });

  testWidgets('falls back to the login page when nothing is recoverable',
      (tester) async {
    const stash = SessionStash(
      accessToken: 'a',
      refreshToken: 'r-stash',
      userId: 'user-1',
    );
    recover = (_) async => null;

    await tester.pumpWidget(gate(stash: stash));
    await tester.pump();
    await tester.pump();

    expect(find.text('LOGIN'), findsOneWidget);
  });

  testWidgets('an expired-session sign-out at runtime recovers from the last pair',
      (tester) async {
    current = _session(refresh: 'r-live');
    final done = Completer<AccountSession?>();
    recover = (_) => done.future;
    await tester.pumpWidget(gate());
    expect(find.text('SHELL'), findsOneWidget);

    // gotrue wiped the session for a rejected refresh.
    current = null;
    auth.add(const AuthState(
      AuthChangeEvent.signedOut,
      null,
      signOutReason: SignOutReason.sessionExpired,
    ));
    await tester.pump();

    // The reader was in the middle of a conversation and the pair rotated
    // behind their back. That is not a sign-out, so the shell stays where it
    // is and the recovery runs behind it — no spinner, no login form.
    expect(find.text('SHELL'), findsOneWidget);
    expect(find.text('Reconnecting to your host…'), findsNothing);
    expect(find.text('LOGIN'), findsNothing);
    expect(recoveries.single.refreshToken, 'r-live');
    expect(SessionRecovery.inFlight, isNotNull);

    // The adoption's own signedIn is not the user signing in: it must not end
    // the recovery, and it must not be adopted as the gate's session while the
    // recovery link still owns the socket.
    current = _session(refresh: 'r-host-next');
    auth.add(AuthState(AuthChangeEvent.signedIn, current));
    await tester.pump();
    expect(recoveries, hasLength(1));
    expect(SessionRecovery.inFlight, isNotNull);
    expect(find.text('SHELL'), findsOneWidget);

    done.complete(AccountSession.fromSupabase(current!));
    await tester.pump();
    await tester.pump();
    expect(find.text('SHELL'), findsOneWidget);
    expect(SessionRecovery.inFlight, isNull);
  });

  testWidgets('a recovery that finds nothing still ends at the login page', (
    tester,
  ) async {
    // The one thing mounting the shell early may never do: leave a genuinely
    // signed-out user inside it.
    current = _session(refresh: 'r-live');
    final done = Completer<AccountSession?>();
    recover = (_) => done.future;
    await tester.pumpWidget(gate());

    current = null;
    auth.add(const AuthState(
      AuthChangeEvent.signedOut,
      null,
      signOutReason: SignOutReason.sessionExpired,
    ));
    await tester.pump();
    expect(find.text('SHELL'), findsOneWidget);

    done.complete(null);
    await tester.pump();
    await tester.pump();
    expect(find.text('LOGIN'), findsOneWidget);
    expect(find.text('SHELL'), findsNothing);
    expect(SessionRecovery.inFlight, isNull);
  });

  testWidgets('a sign-out the user asked for goes straight to login',
      (tester) async {
    current = _session();
    await tester.pumpWidget(gate());

    current = null;
    auth.add(const AuthState(
      AuthChangeEvent.signedOut,
      null,
      signOutReason: SignOutReason.userInitiated,
    ));
    await tester.pump();

    expect(find.text('LOGIN'), findsOneWidget);
    expect(recoveries, isEmpty);
  });

  testWidgets('a token refresh keeps the shell', (tester) async {
    current = _session();
    await tester.pumpWidget(gate());
    current = _session(refresh: 'r2');
    auth.add(AuthState(AuthChangeEvent.tokenRefreshed, current));
    await tester.pump();
    expect(find.text('SHELL'), findsOneWidget);
    expect(recoveries, isEmpty);
  });
}
