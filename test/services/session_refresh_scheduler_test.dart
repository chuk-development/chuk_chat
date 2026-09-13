import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/session_refresh_scheduler.dart';

class _Source implements AccountSessionSource {
  _Source(this._current);

  AccountSession? _current;
  int refreshCalls = 0;
  Completer<void>? gate;

  void adopt(AccountSession next) => _current = next;

  @override
  AccountSession? current() => _current;

  @override
  Future<AccountSession?> refresh() async {
    refreshCalls++;
    final gate = this.gate;
    if (gate != null) await gate.future;
    final before = _current;
    if (before == null) return null;
    _current = AccountSession(
      accessToken: '${before.accessToken}+',
      refreshToken: '${before.refreshToken}+',
      userId: before.userId,
      expiresAt: (before.expiresAt ?? 0) + 3600,
    );
    return _current;
  }
}

void main() {
  const int now = 1_800_000_000;
  DateTime clock() => DateTime.fromMillisecondsSinceEpoch(now * 1000);

  AccountSession session({required int exp, String access = 'a1'}) =>
      AccountSession(
        accessToken: access,
        refreshToken: 'r1',
        userId: 'user-1',
        expiresAt: exp,
      );

  SessionRefreshScheduler scheduler(_Source source) => SessionRefreshScheduler(
        source: source,
        now: clock,
        reconnectGrace: const Duration(milliseconds: 100),
        sinkGrace: const Duration(milliseconds: 50),
      );

  test('leaves a token with life left alone', () async {
    final source = _Source(session(exp: now + 20 * 60));

    expect(await scheduler(source).refreshIfDue(), isFalse);
    expect(source.refreshCalls, 0);
  });

  test('refreshes at the headroom', () async {
    final source = _Source(session(exp: now + 60));

    expect(await scheduler(source).refreshIfDue(), isTrue);
    expect(source.refreshCalls, 1);
    expect(source.current()?.accessToken, 'a1+');
  });

  test('does nothing when signed out', () async {
    final source = _Source(null);

    expect(await scheduler(source).refreshIfDue(), isFalse);
    expect(source.refreshCalls, 0);
  });

  test('with the host away, lets the relay adopt first and spends nothing',
      () async {
    final source = _Source(session(exp: now + 30));
    final s = scheduler(source)
      ..hostAttached = false
      ..reconnectHost = () async {
        // The relay reattached and adopted the pair the host rotated.
        source.adopt(session(exp: now + 3600, access: 'a-host'));
      };

    expect(await s.refreshIfDue(), isTrue);
    expect(source.refreshCalls, 0);
    expect(source.current()?.accessToken, 'a-host');
  });

  test('with the host unreachable, still refreshes itself', () async {
    final source = _Source(session(exp: now + 30));
    final s = scheduler(source)
      ..hostAttached = false
      ..reconnectHost = () async => throw StateError('no host');

    expect(await s.refreshIfDue(), isTrue);
    expect(source.refreshCalls, 1);
  });

  test('with the host slow, does not wait past the grace', () async {
    final source = _Source(session(exp: now + 30));
    final s = scheduler(source)
      ..hostAttached = false
      ..reconnectHost = () => Completer<void>().future; // never completes

    expect(await s.refreshIfDue(), isTrue);
    expect(source.refreshCalls, 1);
  });

  test('with the host attached, refreshes directly', () async {
    int reconnects = 0;
    final source = _Source(session(exp: now + 30));
    final s = scheduler(source)
      ..hostAttached = true
      ..reconnectHost = () async => reconnects++;

    expect(await s.refreshIfDue(), isTrue);
    expect(reconnects, 0);
    expect(source.refreshCalls, 1);
  });

  test('announces a freshly minted token to the sinks', () async {
    // A socket authenticates once, at its handshake. Unless the mint is
    // announced it serves the rest of its life with the old token — which is
    // how a live connection ended up asking a billing question with a token
    // that had expired.
    final source = _Source(session(exp: now + 30));
    final announced = <String>[];
    final s = scheduler(source)
      ..addTokenSink((token) async => announced.add(token));

    expect(await s.refreshIfDue(), isTrue);
    expect(announced, <String>['a1+']);
  });

  test('announces a token adopted from the host', () async {
    final source = _Source(session(exp: now + 30));
    final announced = <String>[];
    final s = scheduler(source)
      ..hostAttached = false
      ..reconnectHost = () async {
        source.adopt(session(exp: now + 3600, access: 'a-host'));
      }
      ..addTokenSink((token) async => announced.add(token));

    expect(await s.refreshIfDue(), isTrue);
    expect(source.refreshCalls, 0);
    expect(announced, <String>['a-host']);
  });

  test('announces nothing when no token was minted', () async {
    final source = _Source(session(exp: now + 20 * 60));
    final announced = <String>[];
    final s = scheduler(source)
      ..addTokenSink((token) async => announced.add(token));

    expect(await s.refreshIfDue(), isFalse);
    expect(announced, isEmpty);
  });

  test('a sink that throws costs neither the refresh nor the session',
      () async {
    final source = _Source(session(exp: now + 30));
    final reached = <String>[];
    final s = scheduler(source)
      ..addTokenSink((token) async => throw StateError('socket gone'))
      ..addTokenSink((token) async => reached.add(token));

    expect(await s.refreshIfDue(), isTrue);
    // The sink after the broken one still hears about the token, and the
    // session is exactly where the refresh left it.
    expect(reached, <String>['a1+']);
    expect(source.current()?.accessToken, 'a1+');
  });

  test('a sink that never returns does not hold the scheduler', () async {
    final source = _Source(session(exp: now + 30));
    final s = scheduler(source)
      ..addTokenSink((token) => Completer<void>().future);

    expect(await s.refreshIfDue(), isTrue);
    expect(source.current()?.accessToken, 'a1+');
  });

  test('the same sink registers once', () {
    final source = _Source(session(exp: now + 30));
    Future<void> sink(String token) async {}
    final s = scheduler(source)
      ..addTokenSink(sink)
      ..addTokenSink(sink);

    expect(s.tokenSinkCount, 1);
    s.removeTokenSink(sink);
    expect(s.tokenSinkCount, 0);
  });

  test('never runs two refreshes at once', () async {
    final source = _Source(session(exp: now + 30))..gate = Completer<void>();
    final s = scheduler(source);

    final first = s.refreshIfDue();
    final second = await s.refreshIfDue();
    source.gate!.complete();

    expect(second, isFalse);
    expect(await first, isTrue);
    expect(source.refreshCalls, 1);
  });
}
