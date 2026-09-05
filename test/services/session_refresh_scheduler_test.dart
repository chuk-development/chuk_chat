import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/session_refresh_scheduler.dart';

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
