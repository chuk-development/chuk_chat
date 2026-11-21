// The cloud computer add-on (CHAT-164): sizes and prices, the checkout body,
// the status fields and the billing calls.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/agents/agents_cloud_box_api.dart';
import 'package:chuk_chat/services/agents_plans.dart';

void main() {
  group('catalog', () {
    test('defaults: Contabo cost + 1 EUR, S recommended', () {
      expect(kAgentsCloudBoxSizeDefaults.map((s) => s.id), <String>[
        's',
        'm',
        'l',
        'xl',
      ]);
      expect(kAgentsCloudBoxSizeDefaults.map((s) => s.priceEur), <num>[
        7.55,
        9.93,
        17.66,
        30.75,
      ]);
      expect(defaultCloudBoxSize(const <AgentsCloudBoxSize>[]).id, 's');
    });

    test('server sizes replace the defaults, cheapest first', () async {
      final AgentsPlanCatalog catalog = await fetchAgentsPlanCatalog(
        baseUrl: 'https://api.test',
        token: () async => 'jwt',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(<String, Object?>{
              'plans': <Object?>[
                <String, Object?>{
                  'id': 'agents_20',
                  'price_eur': 20,
                  'cloud_box': false,
                },
              ],
              'cloud_box_sizes': <Object?>[
                <String, Object?>{
                  'id': 'm',
                  'label': 'M',
                  'vcpu': 6,
                  'ram_gb': 12,
                  'disk_gb': 200,
                  'price_eur': 12.9,
                },
                <String, Object?>{
                  'id': 's',
                  'label': 'S',
                  'vcpu': 4,
                  'ram_gb': 8,
                  'disk_gb': 100,
                  'price_eur': 9.9,
                  'recommended': true,
                },
                <String, Object?>{'id': 'broken'},
              ],
            }),
            200,
          ),
        ),
      );
      expect(catalog.plans.single.includesCloudBox, isFalse);
      expect(catalog.cloudBoxSizes.map((s) => s.id), <String>['s', 'm']);
      expect(catalog.cloudBoxSizes.first.recommended, isTrue);
      expect(catalog.cloudBoxSizes.last.ramGb, 12);
    });

    test('an error gives the built-in plans and sizes', () async {
      final AgentsPlanCatalog catalog = await fetchAgentsPlanCatalog(
        baseUrl: 'https://api.test',
        token: () async => 'jwt',
        client: MockClient((_) async => http.Response('nope', 500)),
      );
      expect(catalog.plans, kAgentsPlanDefaults);
      expect(catalog.cloudBoxSizes, kAgentsCloudBoxSizeDefaults);
    });

    test('a list without sizes keeps the default sizes', () {
      final AgentsPlanCatalog catalog = AgentsPlanCatalog.fromJson(
        <String, Object?>{
          'plans': <Object?>[
            <String, Object?>{'id': 'agents_30', 'price_eur': 30},
          ],
        },
      );
      expect(catalog.plans.single.id, 'agents_30');
      expect(catalog.cloudBoxSizes, kAgentsCloudBoxSizeDefaults);
    });
  });

  group('checkout', () {
    test('plan plus box, plan without box, box only, Plus', () {
      expect(agentsCheckoutBody(planId: 'agents_20', cloudBoxSize: 's'), {
        'plan': 'agents_20',
        'cloud_box_size': 's',
      });
      expect(agentsCheckoutBody(planId: 'agents_20'), {
        'plan': 'agents_20',
        'cloud_box_size': null,
      });
      expect(agentsCheckoutBody(cloudBoxSize: 'm'), {'cloud_box_size': 'm'});
      expect(agentsCheckoutBody(), isNull);
    });

    test('monthly total and euro text', () {
      const AgentsPlan plan = AgentsPlan(id: 'agents_20', priceEur: 20);
      final AgentsCloudBoxSize s = kAgentsCloudBoxSizeDefaults.first;
      expect(formatEuroAmount(agentsMonthlyTotal(plan, s), 'en'), '27.55');
      expect(formatEuroAmount(agentsMonthlyTotal(plan, s), 'de'), '27,55');
      expect(formatEuroAmount(agentsMonthlyTotal(plan, null), 'de'), '20');
      expect(formatEuroAmount(9.93, 'en'), '9.93');
    });
  });

  group('status', () {
    test('reads size, pending change and the sizes on offer', () {
      final AgentsCloudBoxStatus status = AgentsCloudBoxStatus.fromJson(
        <String, Object?>{
          'state': 'running',
          'size': 'm',
          'pending_size': 's',
          'pending_effective_at': '2026-12-01T00:00:00Z',
          'sizes_available': <Object?>[
            's',
            <String, Object?>{'id': 'xl', 'label': 'XL', 'price_eur': 31},
            'unknown',
          ],
        },
      );
      expect(status.booked, isTrue);
      expect(status.size, 'm');
      expect(status.pendingSize, 's');
      expect(status.pendingEffectiveAt, DateTime.utc(2026, 12));
      expect(status.sizesAvailable.map((s) => s.id), <String>['s', 'xl']);
    });

    test('no size and state none: not booked', () {
      expect(
        AgentsCloudBoxStatus.fromJson(<String, Object?>{'state': 'none'})
            .booked,
        isFalse,
      );
    });

    test('error codes from the body', () {
      expect(cloudBoxErrorCode('{"detail":"does_not_fit"}'), 'does_not_fit');
      expect(
        cloudBoxErrorCode('{"detail":{"code":"does_not_fit"}}'),
        'does_not_fit',
      );
      expect(cloudBoxErrorCode('not json'), isNull);
      const AgentsCloudBoxException fit = AgentsCloudBoxException(
        409,
        'does_not_fit',
      );
      expect(fit.doesNotFit, isTrue);
      expect(fit.alreadyBooked, isFalse);
      expect(
        const AgentsCloudBoxException(409, 'http_409').alreadyBooked,
        isTrue,
      );
    });
  });

  group('billing calls', () {
    HttpAgentsCloudBoxApi api(
      List<http.Request> seen,
      http.Response Function(http.Request) answer,
    ) => HttpAgentsCloudBoxApi(
      baseUrl: 'https://api.test',
      token: () async => 'jwt',
      client: MockClient((http.Request request) async {
        seen.add(request);
        return answer(request);
      }),
    );

    test('book, cancel and resize hit their paths', () async {
      final List<http.Request> seen = <http.Request>[];
      final HttpAgentsCloudBoxApi client = api(
        seen,
        (_) => http.Response('{"state":"none","size":"s"}', 200),
      );
      expect((await client.book('s')).size, 's');
      await client.cancel();
      await client.resize('m');
      expect(seen.map((r) => '${r.method} ${r.url.path}'), <String>[
        'POST /v2/agents/cloud-box/subscription',
        'DELETE /v2/agents/cloud-box/subscription',
        'POST /v2/agents/cloud-box/resize',
      ]);
      expect(jsonDecode(seen[0].body), <String, Object?>{'size': 's'});
      expect(jsonDecode(seen[2].body), <String, Object?>{'size': 'm'});
    });

    test('an empty success body is fine', () async {
      final HttpAgentsCloudBoxApi client = api(
        <http.Request>[],
        (_) => http.Response('', 204),
      );
      expect(await client.cancel(), AgentsCloudBoxStatus.none);
    });

    test('402 payment codes: action with a Stripe page, or declined', () async {
      const String url = 'https://invoice.stripe.com/i/acct_1/test_x';
      final HttpAgentsCloudBoxApi action = api(
        <http.Request>[],
        (_) => http.Response(
          jsonEncode(<String, Object?>{
            'detail': 'payment_action_required',
            'hosted_invoice_url': url,
          }),
          402,
        ),
      );
      await expectLater(
        action.book('s'),
        throwsA(
          isA<AgentsCloudBoxException>()
              .having((e) => e.paymentActionRequired, 'action', isTrue)
              .having((e) => e.hostedInvoiceUrl, 'url', url)
              .having((e) => e.noPlan, 'noPlan', isFalse)
              .having((e) => e.paymentFailed, 'failed', isFalse),
        ),
      );
      final HttpAgentsCloudBoxApi declined = api(
        <http.Request>[],
        (_) => http.Response('{"detail":"payment_failed"}', 402),
      );
      await expectLater(
        declined.resize('m'),
        throwsA(
          isA<AgentsCloudBoxException>()
              .having((e) => e.paymentFailed, 'failed', isTrue)
              .having((e) => e.noPlan, 'noPlan', isFalse),
        ),
      );
    });

    test('an invoice URL off Stripe is dropped', () {
      String body(String url) => jsonEncode(<String, Object?>{
        'detail': 'payment_action_required',
        'hosted_invoice_url': url,
      });
      expect(
        cloudBoxHostedInvoiceUrl(body('https://invoice.stripe.com/i/x')),
        'https://invoice.stripe.com/i/x',
      );
      expect(
        cloudBoxHostedInvoiceUrl(body('http://invoice.stripe.com/i/x')),
        isNull,
      );
      expect(
        cloudBoxHostedInvoiceUrl(body('https://evil.example/i/x')),
        isNull,
      );
      expect(cloudBoxHostedInvoiceUrl('not json'), isNull);
      // Without a page the action reads as a declined payment.
      const AgentsCloudBoxException e = AgentsCloudBoxException(
        402,
        'payment_action_required',
      );
      expect(e.paymentActionRequired, isFalse);
      expect(e.paymentFailed, isTrue);
    });

    test('402 and 409 does_not_fit map to the flags', () async {
      final HttpAgentsCloudBoxApi noSub = api(
        <http.Request>[],
        (_) => http.Response('{"detail":"no_subscription"}', 402),
      );
      await expectLater(
        noSub.book('s'),
        throwsA(
          isA<AgentsCloudBoxException>().having(
            (e) => e.noPlan,
            'noPlan',
            isTrue,
          ),
        ),
      );
      final HttpAgentsCloudBoxApi tooSmall = api(
        <http.Request>[],
        (_) => http.Response('{"detail":"does_not_fit"}', 409),
      );
      await expectLater(
        tooSmall.resize('s'),
        throwsA(
          isA<AgentsCloudBoxException>().having(
            (e) => e.doesNotFit,
            'doesNotFit',
            isTrue,
          ),
        ),
      );
    });
  });
}
