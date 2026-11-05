// The server half of webhook automations and the two-step create with its
// rollback (docs/WIRE_CONTRACT.md, "Inbound webhooks", App work 1, 2, 6).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/agents/agents_webhooks_service.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';

const String _hookId = '2A6B0C1E-1111-4222-8333-444455556666';
const String _url = 'https://api.chuk.chat/v1/hooks/wh_secretsecret';

Map<String, dynamic> _row({bool enabled = true}) => <String, dynamic>{
  'id': _hookId.toLowerCase(),
  'secret_prefix': 'wh_secr',
  'device_id': 'dev-1',
  'agent_id': 'host:dev-1',
  'enabled': enabled,
  'created_at': '2026-11-05T09:00:00Z',
  'last_hit_at': null,
};

AgentsAutomation _saved() => AgentsAutomation.fromPayload(<String, dynamic>{
  'id': 'a1',
  'session_key': 'host:dev-1',
  'kind': 'webhook',
  'name': 'GitHub pushes',
  'state': 'active',
  'spec': <String, dynamic>{'webhook_id': _hookId.toLowerCase()},
})!;

void main() {
  late List<http.Request> requests;

  AgentsWebhooksService service(
    http.Response Function(http.Request request) answer,
  ) {
    requests = <http.Request>[];
    return AgentsWebhooksService(
      baseUrl: 'https://api.test',
      token: () async => 'tok',
      client: MockClient((http.Request r) async {
        requests.add(r);
        return answer(r);
      }),
    );
  }

  group('AgentsWebhooksService', () {
    test('create posts device and agent, reads id and the URL once', () async {
      final api = service(
        (_) => http.Response(
          jsonEncode(<String, dynamic>{
            ..._row(),
            'id': _hookId,
            'url': _url,
            'webhook_id': 'wh_secretsecret',
          }),
          201,
        ),
      );
      final created = await api.create(
        deviceId: 'dev-1',
        agentId: 'host:dev-1',
      );
      expect(requests.single.method, 'POST');
      expect(
        requests.single.url.toString(),
        'https://api.test/v1/agents/webhooks',
      );
      expect(requests.single.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(requests.single.body), <String, dynamic>{
        'device_id': 'dev-1',
        'agent_id': 'host:dev-1',
      });
      expect(created.url, _url);
      // The row id is kept in lower case, as the host wants it.
      expect(created.webhook.id, _hookId.toLowerCase());
    });

    test('create leaves unknown ids out of the body', () async {
      final api = service(
        (_) => http.Response(jsonEncode({..._row(), 'url': _url}), 201),
      );
      await api.create();
      expect(jsonDecode(requests.single.body), <String, dynamic>{});
    });

    test('list, patch and delete', () async {
      final api = service((http.Request r) {
        switch (r.method) {
          case 'GET':
            return http.Response(
              jsonEncode(<String, dynamic>{
                'webhooks': <Object?>[_row(), 'junk', <String, dynamic>{}],
              }),
              200,
            );
          case 'PATCH':
            return http.Response(jsonEncode(_row(enabled: false)), 200);
          default:
            return http.Response('{"ok": true}', 200);
        }
      });
      final list = await api.list();
      expect(list.single.id, _hookId.toLowerCase());
      expect(list.single.secretPrefix, 'wh_secr');
      expect(list.single.enabled, isTrue);

      final off = await api.setEnabled(list.single.id, false);
      expect(off.enabled, isFalse);
      expect(requests[1].method, 'PATCH');
      expect(jsonDecode(requests[1].body), <String, dynamic>{'enabled': false});
      expect(
        requests[1].url.path,
        '/v1/agents/webhooks/${_hookId.toLowerCase()}',
      );

      await api.delete(list.single.id);
      expect(requests[2].method, 'DELETE');
    });

    test(
      'errors carry status and the server code; 404 delete is done',
      () async {
        final api = service(
          (http.Request r) => r.method == 'DELETE'
              ? http.Response('{"detail":"not_found"}', 404)
              : http.Response('{"detail":"too_many_webhooks"}', 429),
        );
        await expectLater(
          api.create(),
          throwsA(
            isA<AgentsWebhookException>()
                .having((e) => e.tooMany, 'tooMany', isTrue)
                .having((e) => e.code, 'code', 'too_many_webhooks'),
          ),
        );
        await api.delete('x');
      },
    );

    test('no token: not signed in, nothing sent', () async {
      final api = AgentsWebhooksService(
        baseUrl: 'https://api.test',
        token: () async => null,
        client: MockClient((_) async => fail('must not send')),
      );
      await expectLater(
        api.list(),
        throwsA(
          isA<AgentsWebhookException>().having(
            (e) => e.code,
            'code',
            AgentsWebhookException.notSignedIn,
          ),
        ),
      );
    });

    test('a network failure is code network', () async {
      final api = AgentsWebhooksService(
        baseUrl: 'https://api.test',
        token: () async => 'tok',
        client: MockClient((_) async => throw Exception('down')),
      );
      await expectLater(
        api.list(),
        throwsA(
          isA<AgentsWebhookException>().having(
            (e) => e.code,
            'code',
            AgentsWebhookException.network,
          ),
        ),
      );
    });
  });

  group('createWebhookAutomation', () {
    late List<Map<String, Object?>> sent;

    AgentsWebhooksService api({int status = 201}) => service(
      (http.Request r) => r.method == 'POST'
          ? http.Response(
              status == 201
                  ? jsonEncode(<String, dynamic>{
                      ..._row(),
                      'id': _hookId,
                      'url': _url,
                    })
                  : '{"detail":"too_many_webhooks"}',
              status,
            )
          : http.Response('{"ok": true}', 200),
    );

    WebhookAutomationCreator creator(AutomationSaveResult result) =>
        ({
          required String sessionKey,
          required String kind,
          required Object spec,
          required String prompt,
          String? name,
          bool notifyOnChange = false,
          bool allowChaining = false,
          Object? catchUp,
        }) async {
          sent.add(<String, Object?>{
            'session_key': sessionKey,
            'kind': kind,
            'spec': spec,
            'prompt': prompt,
            'name': name,
          });
          return result;
        };

    setUp(() => sent = <Map<String, Object?>>[]);

    test('server first, then the host row with the row uuid', () async {
      final result = await createWebhookAutomation(
        sessionKey: 'host:dev-1',
        prompt: 'look at the push',
        name: 'GitHub pushes',
        filter: <String, dynamic>{'header': 'x-github-event', 'equals': 'push'},
        debounceSeconds: 20,
        maxWaitSeconds: 600,
        signingSecret: 'supersecret',
        service: api(),
        deviceId: () async => 'dev-1',
        createAutomation: creator(AutomationSaveResult.saved(_saved())),
      );
      expect(result.ok, isTrue);
      expect(result.url, _url);
      expect(jsonDecode(requests.first.body), <String, dynamic>{
        'device_id': 'dev-1',
        'agent_id': 'host:dev-1',
      });
      expect(sent.single['kind'], 'webhook');
      expect(sent.single['spec'], <String, dynamic>{
        'webhook_id': _hookId.toLowerCase(),
        'filter': <String, dynamic>{
          'header': 'x-github-event',
          'equals': 'push',
        },
        'debounce_s': 20,
        'max_wait_s': 600,
        'signing_secret': 'supersecret',
      });
      // Nothing was deleted.
      expect(requests.where((r) => r.method == 'DELETE'), isEmpty);
    });

    test('a host refusal deletes the server webhook again', () async {
      final result = await createWebhookAutomation(
        sessionKey: 'host:dev-1',
        prompt: 'x',
        service: api(),
        deviceId: () async => null,
        createAutomation: creator(
          const AutomationSaveResult.failed('invalid filter: bad path'),
        ),
      );
      expect(result.ok, isFalse);
      expect(result.error, 'invalid filter: bad path');
      expect(result.serverCode, isNull);
      final delete = requests.singleWhere((r) => r.method == 'DELETE');
      expect(delete.url.path, '/v1/agents/webhooks/${_hookId.toLowerCase()}');
    });

    test('a send that throws also deletes the server webhook', () async {
      final result = await createWebhookAutomation(
        sessionKey: 'host:dev-1',
        prompt: 'x',
        service: api(),
        deviceId: () async => null,
        createAutomation: ({
          required String sessionKey,
          required String kind,
          required Object spec,
          required String prompt,
          String? name,
          bool notifyOnChange = false,
          bool allowChaining = false,
          Object? catchUp,
        }) async => throw StateError('socket gone'),
      );
      expect(result.ok, isFalse);
      expect(requests.where((r) => r.method == 'DELETE'), hasLength(1));
    });

    test('a server refusal sends nothing to the host', () async {
      final result = await createWebhookAutomation(
        sessionKey: 'host:dev-1',
        prompt: 'x',
        service: api(status: 429),
        deviceId: () async => null,
        createAutomation: creator(AutomationSaveResult.saved(_saved())),
      );
      expect(result.ok, isFalse);
      expect(result.serverCode, 'too_many_webhooks');
      expect(sent, isEmpty);
    });
  });

  group('spec and checks', () {
    test('webhookAgentIdFor', () {
      expect(webhookAgentIdFor('host:dev-1'), 'host:dev-1');
      expect(webhookAgentIdFor('host:dev-1:fork:ab12cd34'), 'host:dev-1');
      expect(webhookAgentIdFor('a/b'), isNull);
      expect(webhookAgentIdFor(''), isNull);
    });

    test('webhookSpecFor leaves out what is not set', () {
      expect(webhookSpecFor(webhookId: 'ABC'), <String, dynamic>{
        'webhook_id': 'abc',
        'debounce_s': 10,
        'max_wait_s': 300,
      });
    });

    test('signing secret: 8 to 512 printable characters', () {
      expect(isValidWebhookSecret('whsec_abcdef'), isTrue);
      expect(isValidWebhookSecret('short'), isFalse);
      expect(isValidWebhookSecret(' padded secret'), isFalse);
      expect(isValidWebhookSecret('tab\there!'), isFalse);
      expect(isValidWebhookSecret('x' * 513), isFalse);
    });

    test('seconds fields are ranged', () {
      expect(parseWebhookSeconds('10', 300), 10);
      expect(parseWebhookSeconds('301', 300), isNull);
      expect(parseWebhookSeconds('-1', 300), isNull);
      expect(parseWebhookSeconds('x', 300), isNull);
    });

    test('filter leaves from the simple form', () {
      expect(
        webhookFilterLeaf(
          place: 'path',
          target: r'$.action',
          op: 'equals',
          value: 'opened',
        ),
        <String, dynamic>{'path': r'$.action', 'equals': 'opened'},
      );
      expect(
        webhookFilterLeaf(
          place: 'path',
          target: r'$.a.b[0]',
          op: 'equals',
          value: 'true',
        ),
        <String, dynamic>{'path': r'$.a.b[0]', 'equals': true},
      );
      expect(
        webhookFilterLeaf(
          place: 'header',
          target: 'X-GitHub-Event',
          op: 'in',
          value: 'push, pull_request',
        ),
        <String, dynamic>{
          'header': 'x-github-event',
          'in': <Object?>['push', 'pull_request'],
        },
      );
      expect(
        webhookFilterLeaf(
          place: 'path',
          target: r'$.x',
          op: 'exists',
          value: '',
        ),
        <String, dynamic>{'path': r'$.x', 'exists': true},
      );
      expect(
        () => webhookFilterLeaf(
          place: 'path',
          target: 'action',
          op: 'equals',
          value: 'x',
        ),
        throwsFormatException,
      );
      expect(
        () => webhookFilterLeaf(
          place: 'header',
          target: 'x-hub-signature-256',
          op: 'exists',
          value: '',
        ),
        throwsFormatException,
      );
      expect(
        () => webhookFilterLeaf(
          place: 'path',
          target: r'$.x',
          op: 'regex',
          value: '(',
        ),
        throwsFormatException,
      );
    });

    test('the JSON filter field', () {
      expect(parseWebhookFilterJson(''), isNull);
      expect(
        parseWebhookFilterJson('{"any": [{"path": "\$.a", "exists": true}]}'),
        <String, dynamic>{
          'any': <Object?>[
            <String, dynamic>{'path': r'$.a', 'exists': true},
          ],
        },
      );
      expect(() => parseWebhookFilterJson('[1]'), throwsFormatException);
      expect(() => parseWebhookFilterJson('{oops'), throwsFormatException);
    });

    test('an update sends only the spec keys that change', () {
      final before = AgentsAutomation.fromPayload(<String, dynamic>{
        'id': 'a1',
        'session_key': 's',
        'kind': 'webhook',
        'name': 'n',
        'state': 'active',
        'spec': <String, dynamic>{
          'webhook_id': 'abc',
          'debounce_s': 10,
          'max_wait_s': 300,
          'signed': true,
          'filter': <String, dynamic>{'path': r'$.a', 'exists': true},
        },
      })!;
      expect(before.isWebhook, isTrue);
      expect(before.trigger, 'webhook');
      expect(before.specLabel, 'webhook · filtered · signed');
      expect(
        webhookSpecUpdate(
          before: before,
          filter: <String, dynamic>{'path': r'$.a', 'exists': true},
          debounceSeconds: 10,
          maxWaitSeconds: 300,
        ),
        isEmpty,
      );
      expect(
        webhookSpecUpdate(
          before: before,
          filter: null,
          debounceSeconds: 30,
          maxWaitSeconds: 300,
          secret: '',
        ),
        <String, dynamic>{
          'filter': null,
          'debounce_s': 30,
          'signing_secret': '',
        },
      );
    });
  });
}
