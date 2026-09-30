import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_tasks.dart';

class _Delegate implements VoiceTaskDelegate {
  @override
  Future<String> startTask(String task) async => 'id';

  @override
  Stream<VoiceTaskResult> get results => const Stream<VoiceTaskResult>.empty();
}

void main() {
  group('VoiceTaskLedger', () {
    test('tracks started tasks until they resolve', () {
      final _Delegate d = _Delegate();
      final VoiceTaskLedger ledger = VoiceTaskLedger()..reset(d);
      expect(ledger.started(d, 't1'), isTrue);
      expect(ledger.started(d, 't2'), isTrue);
      ledger.resolved('t1');
      expect(ledger.pending, <String>{'t2'});
    });

    test('detach returns the open tasks and drops the delegate', () {
      final _Delegate d = _Delegate();
      final VoiceTaskLedger ledger = VoiceTaskLedger()..reset(d);
      ledger
        ..started(d, 'a')
        ..started(d, 'b');
      expect(ledger.detach(d), unorderedEquals(<String>['a', 'b']));
      expect(ledger.delegate, isNull);
      expect(ledger.pending, isEmpty);
    });

    test('detaching another delegate changes nothing', () {
      final _Delegate current = _Delegate();
      final VoiceTaskLedger ledger = VoiceTaskLedger()..reset(current);
      ledger.started(current, 'a');
      expect(ledger.detach(_Delegate()), isEmpty);
      expect(ledger.delegate, same(current));
      expect(ledger.pending, <String>{'a'});
    });

    test(
      'a task that finishes starting after its delegate left is refused',
      () {
        final _Delegate d = _Delegate();
        final VoiceTaskLedger ledger = VoiceTaskLedger()..reset(d);
        ledger.detach(d);
        expect(ledger.started(d, 'late'), isFalse);
        expect(ledger.started(null, 'x'), isFalse);
        expect(ledger.pending, isEmpty);
      },
    );
  });

  group('deliverWithRetry', () {
    test('the default backoff is 1 s, 3 s, 6 s', () {
      expect(kVoiceResultBackoff, const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 3),
        Duration(seconds: 6),
      ]);
    });

    test('retries after each wait until an attempt succeeds', () async {
      final List<Duration> waited = <Duration>[];
      int attempts = 0;
      final bool ok = await deliverWithRetry(
        () async => ++attempts == 3,
        sleep: (Duration d) async => waited.add(d),
      );
      expect(ok, isTrue);
      expect(attempts, 3);
      expect(waited, const <Duration>[
        Duration(seconds: 1),
        Duration(seconds: 3),
      ]);
    });

    test('gives up after three retries; a throw counts as a failure', () async {
      final List<Duration> waited = <Duration>[];
      int attempts = 0;
      final bool ok = await deliverWithRetry(() async {
        attempts++;
        throw StateError('rpc timeout');
      }, sleep: (Duration d) async => waited.add(d));
      expect(ok, isFalse);
      expect(attempts, 4);
      expect(waited, kVoiceResultBackoff);
    });

    test('stops once the call is no longer live', () async {
      int attempts = 0;
      bool live = true;
      final bool ok = await deliverWithRetry(
        () async {
          attempts++;
          live = false;
          return false;
        },
        stillValid: () => live,
        sleep: (_) async {},
      );
      expect(ok, isFalse);
      expect(attempts, 1);
    });
  });
}
