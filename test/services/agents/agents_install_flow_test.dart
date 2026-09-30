// The install page's state machine, with a scripted wait and pairing.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_install_flow.dart';
import 'package:chuk_chat/services/agents/agents_install_ticket.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _Session implements AccountSessionSource {
  const _Session([this.userId = 'user-1']);

  final String? userId;

  @override
  AccountSession? current() => userId == null
      ? null
      : AccountSession(accessToken: 'jwt', refreshToken: 'r', userId: userId!);

  @override
  Future<AccountSession?> refresh() async => current();
}

/// One pending wait: the test decides when and how it ends.
class _Wait {
  _Wait(this.invite, this.deadline, this.cancel);

  final AgentsPairingInvite invite;
  final DateTime deadline;
  final AgentsClaimCancel cancel;
  final Completer<String?> result = Completer<String?>();
}

void main() {
  late _MemoryStore backend;
  late AgentsInstallTicketStore store;
  late List<_Wait> waits;
  late List<AgentsPairingInvite> paired;
  late DateTime clock;
  Object? pairError;

  setUp(() {
    backend = _MemoryStore();
    store = AgentsInstallTicketStore(backend: backend);
    waits = <_Wait>[];
    paired = <AgentsPairingInvite>[];
    clock = DateTime.utc(2026, 9, 29, 12);
    pairError = null;
  });

  AgentsInstallFlow flow({String? userId = 'user-1'}) => AgentsInstallFlow(
    store: store,
    sessionSource: _Session(userId),
    now: () => clock,
    claimWaiter:
        (
          AgentsPairingInvite invite, {
          required DateTime deadline,
          required AgentsClaimCancel cancel,
        }) {
          final _Wait wait = _Wait(invite, deadline, cancel);
          waits.add(wait);
          cancel.whenCancelled.then((_) {
            if (!wait.result.isCompleted) wait.result.complete(null);
          });
          return wait.result.future;
        },
    pair: (AgentsPairingInvite invite) async {
      paired.add(invite);
      final Object? error = pairError;
      if (error != null) throw error;
    },
  );

  test('start: a fresh ticket, saved, and a wait until its expiry', () async {
    final AgentsInstallFlow f = flow();
    unawaited(f.start());
    await pumpEventQueue();

    expect(f.phase, AgentsInstallPhase.waiting);
    final AgentsInstallTicket ticket = f.ticket!;
    expect(ticket.isWellFormed, isTrue);
    expect(waits.single.invite, ticket.invite);
    expect(waits.single.deadline, ticket.expiresAt);
    expect(
      await store.loadFor(userId: 'user-1', now: clock),
      ticket,
      reason: 'the pending ticket is in secure storage',
    );
    f.dispose();
    expect(waits.single.cancel.isCancelled, isTrue);
  });

  test(
    'claimed: pairs with the ticket invite, deletes the ticket, linked',
    () async {
      final AgentsInstallFlow f = flow();
      unawaited(f.start());
      await pumpEventQueue();
      final AgentsInstallTicket ticket = f.ticket!;

      waits.single.result.complete('host-1');
      await pumpEventQueue();

      expect(paired.single, ticket.invite);
      expect(f.phase, AgentsInstallPhase.linked);
      expect(backend.map, isEmpty, reason: 'the ticket is gone on success');
      f.dispose();
    },
  );

  test('reopening within the lifetime shows the SAME command', () async {
    final AgentsInstallFlow first = flow();
    unawaited(first.start());
    await pumpEventQueue();
    final String token = first.ticket!.token;
    first.dispose();

    clock = clock.add(const Duration(minutes: 12));
    final AgentsInstallFlow second = flow();
    unawaited(second.start());
    await pumpEventQueue();
    expect(second.ticket!.token, token);
    expect(second.phase, AgentsInstallPhase.waiting);
    second.dispose();
  });

  test('another account never sees the ticket', () async {
    final AgentsInstallFlow first = flow();
    unawaited(first.start());
    await pumpEventQueue();
    final String token = first.ticket!.token;
    first.dispose();

    final AgentsInstallFlow other = flow(userId: 'user-2');
    unawaited(other.start());
    await pumpEventQueue();
    expect(other.ticket!.token, isNot(token));
    expect(other.ticket!.userId, 'user-2');
    other.dispose();
  });

  test('New command: cancels the wait, a new token, a new wait', () async {
    final AgentsInstallFlow f = flow();
    unawaited(f.start());
    await pumpEventQueue();
    final String token = f.ticket!.token;

    unawaited(f.newCommand());
    await pumpEventQueue();

    expect(waits, hasLength(2));
    expect(waits.first.cancel.isCancelled, isTrue);
    expect(f.ticket!.token, isNot(token));
    expect(waits.last.invite.pairingChannel, f.ticket!.channel);
    expect(f.phase, AgentsInstallPhase.waiting);
    // A late answer to the old wait changes nothing.
    expect(paired, isEmpty);
    f.dispose();
  });

  test('the wait expires: expired, and New command starts over', () async {
    final AgentsInstallFlow f = flow();
    unawaited(f.start());
    await pumpEventQueue();
    waits.single.result.completeError(
      const AgentsCloudRelayException('expired', code: 'claim_expired'),
    );
    await pumpEventQueue();
    expect(f.phase, AgentsInstallPhase.expired);

    clock = clock.add(const Duration(minutes: 31));
    unawaited(f.newCommand());
    await pumpEventQueue();
    expect(f.phase, AgentsInstallPhase.waiting);
    f.dispose();
  });

  test('a refusal: failed, with the one plain sentence', () async {
    final AgentsInstallFlow f = flow();
    unawaited(f.start());
    await pumpEventQueue();
    waits.single.result.completeError(
      const AgentsCloudRelayException(
        'Your computer could not be linked.',
        code: 'invalid_pairing_channel',
      ),
    );
    await pumpEventQueue();
    expect(f.phase, AgentsInstallPhase.failed);
    expect(f.message, 'Your computer could not be linked.');
    f.dispose();
  });

  test(
    'a pairing that fails: failed, and the spent ticket is dropped',
    () async {
      pairError = StateError('ceremony');
      final AgentsInstallFlow f = flow();
      unawaited(f.start());
      await pumpEventQueue();
      waits.single.result.complete('host-1');
      await pumpEventQueue();
      expect(f.phase, AgentsInstallPhase.failed);
      expect(f.message, isNot(contains(f.ticket!.channel)));
      // The won claim cannot be claimed again: the next open mints a new one.
      expect(backend.map, isEmpty);
      f.dispose();
    },
  );

  test('pair with a code: stops the wait, same pairing sequence', () async {
    final AgentsInstallFlow f = flow();
    unawaited(f.start());
    await pumpEventQueue();
    final AgentsPairingInvite code = AgentsPairingInvite.tryParse(
      'k7m2p9q4w8r3t6y1u5i0o2a7s4d9f3g6h1j8k5l2z7x4c9v6b3-428913',
    )!;
    await f.pairWithInvite(code);
    expect(waits.single.cancel.isCancelled, isTrue);
    expect(paired.single, code);
    expect(f.phase, AgentsInstallPhase.linked);
    f.dispose();
  });

  test('signed out: no ticket and no wait', () async {
    final AgentsInstallFlow f = flow(userId: null);
    await f.start();
    expect(f.phase, AgentsInstallPhase.signedOut);
    expect(f.ticket, isNull);
    expect(waits, isEmpty);
    f.dispose();
  });
}
