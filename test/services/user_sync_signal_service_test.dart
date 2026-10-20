import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/user_sync_signal_service.dart';

void main() {
  final svc = UserSyncSignalService.instance;
  late Map<String, int> calls;
  late int opens;
  late int closes;
  late VoidCallback lastOnSubscribed;

  const tables = <String>[
    UserSyncSignalService.tableEncryptedChats,
    UserSyncSignalService.tableCoworkChats,
    UserSyncSignalService.tableAgentsChatPins,
    UserSyncSignalService.tableUserBilling,
  ];

  Map<String, dynamic> signal(String table) => <String, dynamic>{
    'type': 'broadcast',
    'event': 'changed',
    'payload': <String, dynamic>{'t': table, 'op': 'UPDATE', 'id': 'x'},
  };

  Future<void> settle() =>
      Future<void>.delayed(svc.debounce + const Duration(milliseconds: 40));

  setUp(() async {
    await svc.resetForTest();
    calls = <String, int>{for (final t in tables) t: 0};
    opens = 0;
    closes = 0;
    svc.debounce = const Duration(milliseconds: 30);
    svc.agentsEnabledOverride = true;
    for (final t in tables) {
      svc.handlerOverrides[t] = () async => calls[t] = calls[t]! + 1;
    }
    svc.channelOpenerOverride =
        (userId, {required onSignal, required onSubscribed}) async {
          opens++;
          lastOnSubscribed = onSubscribed;
          return () async => closes++;
        };
  });

  tearDown(() => svc.resetForTest());

  test('a burst collapses into one call per table', () async {
    await svc.start('u1');
    for (var i = 0; i < 5; i++) {
      svc.handleSignal(signal(UserSyncSignalService.tableEncryptedChats));
      svc.handleSignal(signal(UserSyncSignalService.tableUserBilling));
    }
    await settle();
    expect(calls[UserSyncSignalService.tableEncryptedChats], 1);
    expect(calls[UserSyncSignalService.tableUserBilling], 1);
    expect(calls[UserSyncSignalService.tableCoworkChats], 0);
  });

  test('each table routes to its own handler', () async {
    await svc.start('u1');
    for (final t in tables) {
      svc.handleSignal(signal(t));
      await settle();
      expect(calls[t], 1, reason: t);
    }
    expect(calls.values.every((c) => c == 1), isTrue);
  });

  test('an unknown table is ignored', () async {
    await svc.start('u1');
    svc.handleSignal(signal('profiles'));
    svc.handleSignal(<String, dynamic>{'payload': 'garbage'});
    expect(svc.pendingTimers, 0);
    await settle();
    expect(calls.values.every((c) => c == 0), isTrue);
  });

  test('cowork_chats and pins are skipped when Agents is off', () async {
    svc.agentsEnabledOverride = false;
    await svc.start('u1');
    svc.handleSignal(signal(UserSyncSignalService.tableCoworkChats));
    svc.handleSignal(signal(UserSyncSignalService.tableAgentsChatPins));
    lastOnSubscribed();
    await settle();
    expect(calls[UserSyncSignalService.tableCoworkChats], 0);
    expect(calls[UserSyncSignalService.tableAgentsChatPins], 0);
    expect(calls[UserSyncSignalService.tableEncryptedChats], 1);
    expect(calls[UserSyncSignalService.tableUserBilling], 1);
  });

  test('subscribed runs every handler once (catch-up)', () async {
    await svc.start('u1');
    lastOnSubscribed();
    lastOnSubscribed();
    await settle();
    expect(calls.values.every((c) => c == 1), isTrue);
  });

  test('start is idempotent for the same user', () async {
    await svc.start('u1');
    await svc.start('u1');
    expect(opens, 1);
    await svc.start('u2');
    expect(opens, 2);
    expect(closes, 1);
  });

  test('stop cancels pending timers', () async {
    await svc.start('u1');
    svc.handleSignal(signal(UserSyncSignalService.tableEncryptedChats));
    expect(svc.pendingTimers, 1);
    await svc.stop();
    expect(svc.pendingTimers, 0);
    expect(closes, 1);
    await settle();
    expect(calls[UserSyncSignalService.tableEncryptedChats], 0);
  });

  test('after pause no handler runs, resume subscribes again', () async {
    await svc.start('u1');
    svc.handleSignal(signal(UserSyncSignalService.tableEncryptedChats));
    await svc.pause();
    expect(svc.isOpen, isFalse);
    expect(svc.userId, 'u1');
    expect(closes, 1);
    // A late signal or join callback while paused does nothing.
    svc.handleSignal(signal(UserSyncSignalService.tableUserBilling));
    lastOnSubscribed();
    await settle();
    expect(calls.values.every((c) => c == 0), isTrue);

    // A session event while paused does not open the channel.
    await svc.start('u1');
    expect(opens, 1);

    await svc.resume();
    expect(opens, 2);
    expect(svc.isOpen, isTrue);
    lastOnSubscribed();
    await settle();
    expect(calls.values.every((c) => c == 1), isTrue);

    // A second resume (desktop focus) is a no-op.
    await svc.resume();
    expect(opens, 2);
  });

  test('resume without a user does nothing', () async {
    await svc.resume();
    expect(opens, 0);
  });

  test('default user_billing handler fires billingChanged', () async {
    svc.handlerOverrides.remove(UserSyncSignalService.tableUserBilling);
    var fired = 0;
    final sub = svc.billingChanged.listen((_) => fired++);
    await svc.start('u1');
    svc.handleSignal(signal(UserSyncSignalService.tableUserBilling));
    svc.handleSignal(signal(UserSyncSignalService.tableUserBilling));
    await settle();
    await sub.cancel();
    expect(fired, 1);
  });
}
