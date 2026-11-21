// The zero-click cloud computer setup (CHAT-164), with a fake server, a
// scripted relay wait and a scripted pairing.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_box_api.dart';
import 'package:chuk_chat/services/agents/agents_cloud_box_flow.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_install_ticket.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';
import 'package:chuk_chat/services/agents_plans.dart';

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

class _FakeApi implements AgentsCloudBoxApi {
  AgentsCloudBoxStatus fetchAnswer = AgentsCloudBoxStatus.none;
  AgentsCloudBoxStatus requestAnswer = const AgentsCloudBoxStatus(
    state: AgentsCloudBoxState.settingUp,
  );
  Object? fetchError;
  Object? requestError;
  int fetches = 0;
  final List<String> tokens = <String>[];

  @override
  Future<AgentsCloudBoxStatus> fetch() async {
    fetches++;
    if (fetchError case final Object error) throw error;
    return fetchAnswer;
  }

  @override
  Future<AgentsCloudBoxStatus> request(String pairingToken) async {
    tokens.add(pairingToken);
    if (requestError case final Object error) throw error;
    return requestAnswer;
  }
}

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
  late _FakeApi api;
  late List<_Wait> waits;
  late List<AgentsPairingInvite> paired;
  late DateTime clock;
  bool? included;

  setUp(() {
    backend = _MemoryStore();
    store = AgentsInstallTicketStore(
      backend: backend,
      storageKey: AgentsInstallTicketStore.cloudBoxStorageKey,
    );
    api = _FakeApi();
    waits = <_Wait>[];
    paired = <AgentsPairingInvite>[];
    clock = DateTime.utc(2026, 11, 21, 12);
    included = true;
  });

  AgentsCloudBoxFlow flow({String? userId = 'user-1'}) => AgentsCloudBoxFlow(
    api: api,
    store: store,
    sessionSource: _Session(userId),
    planIncludesBox: () => included,
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
    pair: (AgentsPairingInvite invite) async => paired.add(invite),
  );

  test('a plan with a box: token sent, wait, pair, linked', () async {
    final AgentsCloudBoxFlow f = flow();
    unawaited(f.maybeStart());
    await pumpEventQueue();

    expect(f.phase, AgentsCloudBoxPhase.settingUp);
    expect(f.phase.visible, isTrue);
    expect(api.tokens, hasLength(1));
    final AgentsInstallTicket? saved = await store.loadFor(
      userId: 'user-1',
      now: clock,
    );
    expect(saved, isNotNull, reason: 'the token is kept in secure storage');
    expect(api.tokens.single, saved!.token);
    expect(waits.single.invite, saved.invite);
    expect(backend.map.keys, <String>[
      AgentsInstallTicketStore.cloudBoxStorageKey,
    ], reason: 'kept apart from the install page ticket');

    waits.single.result.complete('host-device');
    await pumpEventQueue();
    expect(paired.single, saved.invite);
    expect(f.phase, AgentsCloudBoxPhase.linked);
    expect(backend.map, isEmpty, reason: 'a used token is deleted');
    f.dispose();
  });

  test('maybeStart fires once: a second signal sends nothing', () async {
    final AgentsCloudBoxFlow f = flow();
    unawaited(f.maybeStart());
    unawaited(f.maybeStart());
    await pumpEventQueue();
    unawaited(f.maybeStart());
    await pumpEventQueue();
    expect(api.fetches, 1);
    expect(api.tokens, hasLength(1));
    f.dispose();
  });

  test('the plan says no: hidden, no request, no token', () async {
    included = false;
    final AgentsCloudBoxFlow f = flow();
    await f.maybeStart();
    expect(f.phase, AgentsCloudBoxPhase.hidden);
    expect(f.hiddenForPlan, isTrue);
    expect(api.tokens, isEmpty);
    expect(backend.map, isEmpty);
    f.dispose();
  });

  test('plan unknown and 402: hidden quietly', () async {
    included = null;
    api.requestError = const AgentsCloudBoxException(402, 'http_402');
    final AgentsCloudBoxFlow f = flow();
    await f.maybeStart();
    expect(f.phase, AgentsCloudBoxPhase.hidden);
    expect(api.tokens, hasLength(1));
    expect(backend.map, isEmpty, reason: 'the unused token is dropped');
    f.dispose();
  });

  test('404 (feature off on the server): hidden', () async {
    api.fetchError = const AgentsCloudBoxException(404, 'http_404');
    final AgentsCloudBoxFlow f = flow();
    await f.maybeStart();
    expect(f.phase, AgentsCloudBoxPhase.hidden);
    expect(api.tokens, isEmpty);
    f.dispose();
  });

  test('suspended: no wait, the billing screen', () async {
    api.fetchAnswer = const AgentsCloudBoxStatus(
      state: AgentsCloudBoxState.suspended,
    );
    final AgentsCloudBoxFlow f = flow();
    await f.maybeStart();
    expect(f.phase, AgentsCloudBoxPhase.suspended);
    expect(api.tokens, isEmpty);
    expect(waits, isEmpty);
    f.dispose();
  });

  test('a server error for a paying user: failed, retry works', () async {
    api.requestError = const AgentsCloudBoxException(500, 'http_500');
    final AgentsCloudBoxFlow f = flow();
    await f.maybeStart();
    expect(f.phase, AgentsCloudBoxPhase.failed);

    api.requestError = null;
    clock = clock.add(const Duration(seconds: 11));
    unawaited(f.retry());
    await pumpEventQueue();
    expect(f.phase, AgentsCloudBoxPhase.settingUp);
    expect(
      api.tokens.toSet(),
      hasLength(1),
      reason: 'the retry sends the same pending token',
    );
    f.dispose();
  });

  test('an expired token: a fresh one is sent again', () async {
    final AgentsCloudBoxFlow f = flow();
    unawaited(f.maybeStart());
    await pumpEventQueue();
    waits.first.result.completeError(
      const AgentsCloudRelayException('expired', code: 'claim_expired'),
    );
    await pumpEventQueue();
    expect(api.tokens, hasLength(2));
    expect(api.tokens[0], isNot(api.tokens[1]));
    expect(f.phase, AgentsCloudBoxPhase.settingUp);
    f.dispose();
  });

  testWidgets('slow: after slowAfter the screen says it takes longer', (
    WidgetTester tester,
  ) async {
    final AgentsCloudBoxFlow f = AgentsCloudBoxFlow(
      api: api,
      store: store,
      sessionSource: const _Session(),
      planIncludesBox: () => true,
      slowAfter: const Duration(seconds: 90),
      claimWaiter: (
        AgentsPairingInvite invite, {
        required DateTime deadline,
        required AgentsClaimCancel cancel,
      }) => Completer<String?>().future,
      pair: (_) async {},
    );
    unawaited(f.maybeStart());
    await tester.pump();
    expect(f.phase, AgentsCloudBoxPhase.settingUp);
    await tester.pump(const Duration(seconds: 91));
    expect(f.phase, AgentsCloudBoxPhase.slow);
    expect(f.phase.visible, isTrue);
    f.dispose();
  });

  testWidgets('resume: a failed setup runs again, never twice within 10 s', (
    WidgetTester tester,
  ) async {
    api.requestError = const AgentsCloudBoxException(0, 'network');
    DateTime now = DateTime.utc(2026);
    final AgentsCloudBoxFlow f = AgentsCloudBoxFlow(
      api: api,
      store: store,
      sessionSource: const _Session(),
      planIncludesBox: () => true,
      now: () => now,
      claimWaiter: (
        AgentsPairingInvite invite, {
        required DateTime deadline,
        required AgentsClaimCancel cancel,
      }) => Completer<String?>().future,
      pair: (_) async {},
    );
    unawaited(f.maybeStart());
    await tester.pump();
    expect(f.phase, AgentsCloudBoxPhase.failed);
    expect(api.fetches, 1);

    now = now.add(const Duration(seconds: 2));
    unawaited(f.resumed());
    unawaited(f.resumed());
    await tester.pump();
    expect(api.fetches, 1, reason: 'inside the 10 s gap: delayed');

    api.requestError = null;
    now = now.add(const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 8));
    await tester.pump();
    expect(api.fetches, 2, reason: 'one run after the gap, not two');
    expect(f.phase, AgentsCloudBoxPhase.settingUp);
    f.dispose();
  });

  test('stop: a computer arrived some other way, the wait ends', () async {
    final AgentsCloudBoxFlow f = flow();
    unawaited(f.maybeStart());
    await pumpEventQueue();
    f.stop();
    expect(waits.single.cancel.isCancelled, isTrue);
    expect(f.phase, AgentsCloudBoxPhase.idle);
    f.dispose();
  });

  test('planChanged: a hidden flow starts once the plan says yes', () async {
    included = false;
    final AgentsCloudBoxFlow f = flow();
    await f.maybeStart();
    expect(f.phase, AgentsCloudBoxPhase.hidden);
    included = true;
    clock = clock.add(const Duration(seconds: 11));
    unawaited(f.planChanged());
    await pumpEventQueue();
    expect(f.phase, AgentsCloudBoxPhase.settingUp);
    f.dispose();
  });

  test('signed out: stays idle, sends nothing', () async {
    final AgentsCloudBoxFlow f = flow(userId: null);
    await f.maybeStart();
    expect(f.phase, AgentsCloudBoxPhase.idle);
    expect(api.fetches, 0);
    f.dispose();
  });

  group('HttpAgentsCloudBoxApi', () {
    test('GET and POST shape, token only in the body', () async {
      final List<http.Request> seen = <http.Request>[];
      final HttpAgentsCloudBoxApi http0 = HttpAgentsCloudBoxApi(
        baseUrl: 'https://api.test',
        token: () async => 'jwt',
        client: MockClient((http.Request request) async {
          seen.add(request);
          return http.Response(
            jsonEncode(<String, Object?>{
              'state': 'running',
              'last_backup_at': '2026-11-20T03:00:00Z',
            }),
            200,
          );
        }),
      );
      final AgentsCloudBoxStatus got = await http0.request('p-1');
      expect(got.state, AgentsCloudBoxState.running);
      expect(got.lastBackupAt, DateTime.utc(2026, 11, 20, 3));
      expect(seen.single.method, 'POST');
      expect(
        seen.single.url.toString(),
        'https://api.test/v2/agents/cloud-box',
      );
      expect(jsonDecode(seen.single.body), <String, Object?>{
        'pairing_token': 'p-1',
      });
      expect(seen.single.headers['Authorization'], 'Bearer jwt');
    });

    test('404 and 402 map to the exception flags', () async {
      for (final int code in <int>[404, 402]) {
        final HttpAgentsCloudBoxApi http0 = HttpAgentsCloudBoxApi(
          baseUrl: 'https://api.test',
          token: () async => 'jwt',
          client: MockClient((_) async => http.Response('{}', code)),
        );
        await expectLater(
          http0.fetch(),
          throwsA(
            isA<AgentsCloudBoxException>()
                .having((e) => e.unavailable, 'unavailable', code == 404)
                .having((e) => e.noPlan, 'noPlan', code == 402),
          ),
        );
      }
    });

    test('an unknown state reads as none', () {
      expect(
        AgentsCloudBoxStatus.fromJson(<String, Object?>{'state': 'exploded'}),
        AgentsCloudBoxStatus.none,
      );
    });
  });

  group('agents plans', () {
    test('server list replaces the defaults, cheapest first', () async {
      final List<AgentsPlan> plans = await fetchAgentsPlans(
        baseUrl: 'https://api.test',
        token: () async => 'jwt',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{
              'plans': <Object?>[
                <String, Object?>{'id': 'agents_40', 'price_eur': 40},
                <String, Object?>{
                  'id': 'agents_20',
                  'price_eur': 20,
                  'credit_eur': 8,
                },
              ],
            }),
            200,
          ),
        ),
      );
      expect(plans.map((p) => p.id), <String>['agents_20', 'agents_40']);
      expect(plans.first.creditEur, 8);
    });

    test('404 falls back to 20, 30, 40', () async {
      final List<AgentsPlan> plans = await fetchAgentsPlans(
        baseUrl: 'https://api.test',
        token: () async => 'jwt',
        client: MockClient((_) async => http.Response('', 404)),
      );
      expect(plans.map((p) => p.priceEur), <int>[20, 30, 40]);
      expect(plans.every((p) => p.includesCloudBox), isTrue);
    });

    test('user status flag', () {
      expect(agentsPlanIncludesCloudBox(null), isNull);
      expect(agentsPlanIncludesCloudBox(<String, dynamic>{}), isNull);
      expect(
        agentsPlanIncludesCloudBox(<String, dynamic>{
          'cloud_box_included': true,
        }),
        isTrue,
      );
    });
  });
}
