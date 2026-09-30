// The install ticket: the token contract, the command, and the one pending
// ticket in secure storage.

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

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

void main() {
  final DateTime t0 = DateTime.utc(2026, 9, 29, 12);

  group('minting', () {
    test('P is 64 lowercase hex, D is 8 digits, the token is P-D', () {
      for (var i = 0; i < 50; i++) {
        final AgentsInstallTicket ticket = AgentsInstallTicket.mint(
          userId: 'user-1',
          now: t0,
        );
        expect(ticket.channel, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(ticket.digits, matches(RegExp(r'^[0-9]{8}$')));
        expect(ticket.token, '${ticket.channel}-${ticket.digits}');
        expect(ticket.isWellFormed, isTrue);
      }
    });

    test('the default source is Random.secure: two mints never repeat', () {
      final Set<String> seen = <String>{};
      for (var i = 0; i < 200; i++) {
        seen.add(AgentsInstallTicket.mint(userId: 'u', now: t0).token);
      }
      expect(seen, hasLength(200));
    });

    test('a given source decides every character (the source is used)', () {
      final AgentsInstallTicket a = AgentsInstallTicket.mint(
        userId: 'u',
        now: t0,
        random: Random(7),
      );
      final AgentsInstallTicket b = AgentsInstallTicket.mint(
        userId: 'u',
        now: t0,
        random: Random(7),
      );
      expect(a.token, b.token);
    });

    test('valid for 30 minutes from minting', () {
      final AgentsInstallTicket ticket = AgentsInstallTicket.mint(
        userId: 'u',
        now: t0,
      );
      expect(ticket.createdAt, t0);
      expect(ticket.expiresAt, t0.add(const Duration(minutes: 30)));
      expect(kAgentsInstallTicketLifetime, const Duration(minutes: 30));
      expect(ticket.isExpiredAt(t0.add(const Duration(minutes: 29))), isFalse);
      expect(ticket.isExpiredAt(t0.add(const Duration(minutes: 30))), isTrue);
      expect(
        ticket.remainingAt(t0.add(const Duration(minutes: 40))),
        Duration.zero,
      );
    });

    test('the invite: channel P, §15 code P-D, the default relay', () {
      final AgentsInstallTicket ticket = AgentsInstallTicket.mint(
        userId: 'u',
        now: t0,
      );
      final AgentsPairingInvite invite = ticket.invite;
      expect(invite.pairingChannel, ticket.channel);
      expect(invite.pairingCode, '${ticket.channel}-${ticket.digits}');
      expect(invite.codeDigits, ticket.digits);
      expect(invite.relayBase, Uri.parse(kDefaultAgentsRelayBase));
    });

    test('toString never carries the token', () {
      final AgentsInstallTicket ticket = AgentsInstallTicket.mint(
        userId: 'u',
        now: t0,
      );
      expect(ticket.toString(), isNot(contains(ticket.channel)));
      expect(ticket.toString(), isNot(contains(ticket.digits)));
    });
  });

  group('the command', () {
    test('is the installer piped to bash with the token', () {
      const String token =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
          '-12345678';
      expect(
        agentsInstallCommand(token),
        'curl -fsSL https://api.chuk.chat/agents/install.sh | bash -s -- '
        '--token=$token',
      );
    });

    test('the installer and the relay name the same host', () {
      expect(
        Uri.parse(kAgentsInstallScriptUrl).host,
        Uri.parse(kDefaultAgentsRelayBase).host,
      );
      expect(Uri.parse(kAgentsInstallScriptUrl).scheme, 'https');
    });

    test('a ticket renders its own command', () {
      final AgentsInstallTicket ticket = AgentsInstallTicket.mint(
        userId: 'u',
        now: t0,
      );
      expect(ticket.command, endsWith('--token=${ticket.token}'));
    });
  });

  group('the store', () {
    late _MemoryStore backend;
    late AgentsInstallTicketStore store;

    setUp(() {
      backend = _MemoryStore();
      store = AgentsInstallTicketStore(backend: backend);
    });

    test('persists and reads back the same ticket', () async {
      final AgentsInstallTicket made = await store.loadOrMint(
        userId: 'user-1',
        now: t0,
      );
      final AgentsInstallTicket? again = await store.loadFor(
        userId: 'user-1',
        now: t0.add(const Duration(minutes: 10)),
      );
      expect(again, made);
      // A second loadOrMint within the lifetime is the SAME command.
      final AgentsInstallTicket third = await store.loadOrMint(
        userId: 'user-1',
        now: t0.add(const Duration(minutes: 20)),
      );
      expect(third.token, made.token);
    });

    test('an expired ticket is discarded and deleted', () async {
      final AgentsInstallTicket made = await store.loadOrMint(
        userId: 'user-1',
        now: t0,
      );
      expect(
        await store.loadFor(
          userId: 'user-1',
          now: t0.add(const Duration(minutes: 30)),
        ),
        isNull,
      );
      expect(backend.map, isEmpty);
      final AgentsInstallTicket fresh = await store.loadOrMint(
        userId: 'user-1',
        now: t0.add(const Duration(minutes: 31)),
      );
      expect(fresh.token, isNot(made.token));
    });

    test('a ticket of another account is discarded and deleted', () async {
      await store.loadOrMint(userId: 'user-1', now: t0);
      expect(await store.loadFor(userId: 'user-2', now: t0), isNull);
      expect(backend.map, isEmpty);
      // And user-1 does not get it back either: it is gone.
      expect(await store.loadFor(userId: 'user-1', now: t0), isNull);
    });

    test('a corrupt or malformed record reads as none', () async {
      backend.map['cowork_install_ticket'] = 'not json';
      expect(await store.loadFor(userId: 'u', now: t0), isNull);
      backend.map['cowork_install_ticket'] = jsonEncode(<String, dynamic>{
        'version': 1,
        'channel': 'SHORT',
        'digits': '1234',
        'created_at_ms': t0.millisecondsSinceEpoch,
        'expires_at_ms': t0.millisecondsSinceEpoch + 60000,
        'user_id': 'u',
      });
      expect(await store.loadFor(userId: 'u', now: t0), isNull);
    });

    test('delete removes it (a linked computer)', () async {
      await store.loadOrMint(userId: 'user-1', now: t0);
      await store.delete();
      expect(await store.loadFor(userId: 'user-1', now: t0), isNull);
    });

    test('mintAndSave replaces the pending ticket (New command)', () async {
      final AgentsInstallTicket first = await store.loadOrMint(
        userId: 'user-1',
        now: t0,
      );
      final AgentsInstallTicket second = await store.mintAndSave(
        userId: 'user-1',
        now: t0.add(const Duration(minutes: 1)),
      );
      expect(second.token, isNot(first.token));
      final AgentsInstallTicket? read = await store.loadFor(
        userId: 'user-1',
        now: t0.add(const Duration(minutes: 2)),
      );
      expect(read, second);
    });
  });
}
