// The cloud computer add-on in the UI (CHAT-164): the pricing card with its
// switch and total, booking later (402 goes to checkout), changing the size
// and cancelling.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_cloud_box_api.dart';
import 'package:chuk_chat/services/agents_plans.dart';
import 'package:chuk_chat/widgets/agents_cloud_box_addon.dart';
import 'package:chuk_chat/widgets/agents_cloud_box_billing_sheets.dart';
import 'package:chuk_chat/widgets/agents_cloud_box_settings_section.dart';

class _Billing implements AgentsCloudBoxBillingApi {
  _Billing({this.status = AgentsCloudBoxStatus.none, this.error});

  AgentsCloudBoxStatus status;
  Object? error;
  final List<String> calls = <String>[];

  Future<AgentsCloudBoxStatus> _answer(String call) async {
    calls.add(call);
    final Object? e = error;
    if (e != null) throw e;
    return status;
  }

  @override
  Future<AgentsCloudBoxStatus> fetch() async => status;

  @override
  Future<AgentsCloudBoxStatus> book(String size) => _answer('book $size');

  @override
  Future<AgentsCloudBoxStatus> cancel() => _answer('cancel');

  @override
  Future<AgentsCloudBoxStatus> resize(String size) => _answer('resize $size');
}

Widget _app(Widget child) => MaterialApp(
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    DefaultMaterialLocalizations.delegate,
    DefaultWidgetsLocalizations.delegate,
  ],
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// A button that opens [open] with a live context.
Widget _opener(Future<void> Function(BuildContext) open) => Builder(
  builder: (BuildContext context) => TextButton(
    key: const ValueKey<String>('open'),
    onPressed: () => open(context),
    child: const Text('open'),
  ),
);

Future<void> _tall(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  final AppLocalizations en = AppLocalizations(const Locale('en'));

  test('total line: plan alone or plan plus add-on', () {
    const AgentsPlan plan = AgentsPlan(id: 'agents_30', priceEur: 30);
    expect(agentsTotalLine(en, plan, null), 'Total: €30/month');
    expect(
      agentsTotalLine(en, plan, kAgentsCloudBoxSizeDefaults[1]),
      'Total with cloud computer: €39.93/month',
    );
  });

  testWidgets('pricing card: pre-on, size changes the price, off hides it', (
    WidgetTester tester,
  ) async {
    await _tall(tester);
    bool on = true;
    String size = 's';
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) =>
              AgentsCloudBoxAddonCard(
                sizes: kAgentsCloudBoxSizeDefaults,
                enabled: on,
                selectedId: size,
                onEnabledChanged: (bool v) => setState(() => on = v),
                onSizeChanged: (AgentsCloudBoxSize s) =>
                    setState(() => size = s.id),
              ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Recommended'), findsWidgets);
    expect(find.text('plus €7.55/month'), findsOneWidget);

    await tester.tap(find.byKey(AgentsCloudBoxSizePicker.optionKey('l')));
    await tester.pump();
    expect(size, 'l');
    expect(find.text('plus €17.66/month'), findsOneWidget);

    await tester.tap(find.byKey(AgentsCloudBoxAddonCard.switchKey));
    await tester.pump();
    expect(on, isFalse);
    expect(find.byKey(AgentsCloudBoxAddonCard.priceKey), findsNothing);
    expect(find.byKey(AgentsCloudBoxSizePicker.optionKey('s')), findsNothing);
  });

  testWidgets('book later: 402 opens checkout with the size pre-selected', (
    WidgetTester tester,
  ) async {
    await _tall(tester);
    final _Billing api = _Billing(
      error: const AgentsCloudBoxException(402, 'no_subscription'),
    );
    String? checkoutSize;
    bool? booked;
    await tester.pumpWidget(
      _app(
        _opener(
          (BuildContext context) async => booked = await showCloudBoxBookSheet(
            context,
            api: api,
            openCheckout: (_, String size) async => checkoutSize = size,
            onBooked: () async => fail('not booked'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('charged pro rata now'), findsOneWidget);

    await tester.tap(find.byKey(AgentsCloudBoxSizePicker.optionKey('m')));
    await tester.pump();
    expect(find.text('Book for €9.93/month'), findsOneWidget);
    await tester.tap(find.byKey(CloudBoxBookSheet.confirmKey));
    await tester.pumpAndSettle();

    expect(api.calls, <String>['book m']);
    expect(checkoutSize, 'm');
    expect(booked, isFalse);
  });

  testWidgets('book later: success runs the after-booking step', (
    WidgetTester tester,
  ) async {
    await _tall(tester);
    final _Billing api = _Billing();
    var refreshed = 0;
    bool? booked;
    await tester.pumpWidget(
      _app(
        _opener(
          (BuildContext context) async => booked = await showCloudBoxBookSheet(
            context,
            api: api,
            onBooked: () async => refreshed++,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CloudBoxBookSheet.confirmKey));
    await tester.pumpAndSettle();
    expect(api.calls, <String>['book s']);
    expect(refreshed, 1);
    expect(booked, isTrue);
  });

  testWidgets('book later: 409 says it is booked already', (
    WidgetTester tester,
  ) async {
    await _tall(tester);
    final _Billing api = _Billing(
      error: const AgentsCloudBoxException(409, 'http_409'),
    );
    await tester.pumpWidget(
      _app(
        _opener(
          (BuildContext context) =>
              showCloudBoxBookSheet(context, api: api, onBooked: () async {}),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CloudBoxBookSheet.confirmKey));
    await tester.pumpAndSettle();
    expect(
      find.text('You have already booked a cloud computer.'),
      findsOneWidget,
    );
  });

  testWidgets('resize: upgrade now, downgrade at period end, does_not_fit', (
    WidgetTester tester,
  ) async {
    await _tall(tester);
    final _Billing api = _Billing(
      error: const AgentsCloudBoxException(409, 'does_not_fit'),
    );
    const AgentsCloudBoxStatus status = AgentsCloudBoxStatus(
      state: AgentsCloudBoxState.running,
      size: 'm',
    );
    await tester.pumpWidget(
      _app(
        _opener(
          (BuildContext context) => showCloudBoxResizeSheet(
            context,
            status: status,
            api: api,
            onChanged: () async {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    // The current size: no note, no confirm.
    expect(find.text('Current'), findsOneWidget);
    expect(find.byKey(CloudBoxResizeSheet.confirmKey), findsNothing);

    await tester.tap(find.byKey(AgentsCloudBoxSizePicker.optionKey('l')));
    await tester.pump();
    expect(find.textContaining('restarts once'), findsOneWidget);

    await tester.tap(find.byKey(AgentsCloudBoxSizePicker.optionKey('s')));
    await tester.pump();
    expect(
      find.textContaining('at the end of the billing period'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(CloudBoxResizeSheet.confirmKey));
    await tester.pumpAndSettle();
    expect(api.calls, <String>['resize s']);
    expect(find.byKey(CloudBoxResizeSheet.errorKey), findsOneWidget);
    expect(find.textContaining('does not fit'), findsOneWidget);
  });

  testWidgets('cancel: asks first, Keep does nothing, confirm cancels', (
    WidgetTester tester,
  ) async {
    final _Billing api = _Billing();
    var changed = 0;
    await tester.pumpWidget(
      _app(
        _opener(
          (BuildContext context) => confirmCloudBoxCancel(
            context,
            api: api,
            onChanged: () async => changed++,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    expect(find.textContaining('kept for 90 days'), findsOneWidget);
    await tester.tap(find.byKey(CloudBoxCancelDialog.keepKey));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);

    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(CloudBoxCancelDialog.confirmKey));
    await tester.pumpAndSettle();
    expect(api.calls, <String>['cancel']);
    expect(changed, 1);
  });

  testWidgets('settings: no add-on offers booking', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AgentsCloudBoxSettingsSection(
          api: _Billing(),
          paymentsEnabled: true,
          onChanged: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AgentsCloudBoxSettingsSection.bookKey), findsOneWidget);
    expect(find.byKey(AgentsCloudBoxSettingsSection.sizeKey), findsNothing);
  });

  testWidgets('settings: no add-on and no direct payments shows nothing', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AgentsCloudBoxSettingsSection(api: _Billing(), paymentsEnabled: false),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AgentsCloudBoxSettingsSection.bookKey), findsNothing);
    expect(find.text('Cloud computer'), findsNothing);
  });

  testWidgets('settings: booked shows size, pending change and cancel', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AgentsCloudBoxSettingsSection(
          api: _Billing(
            status: AgentsCloudBoxStatus(
              state: AgentsCloudBoxState.running,
              size: 'm',
              pendingSize: 's',
              pendingEffectiveAt: DateTime(2026, 12, 1),
            ),
          ),
          paymentsEnabled: true,
          onChanged: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(AgentsCloudBoxSettingsSection.rowKey), findsOneWidget);
    expect(find.byKey(AgentsCloudBoxSettingsSection.sizeKey), findsOneWidget);
    expect(find.textContaining('Changes to S on'), findsOneWidget);
    expect(find.byKey(AgentsCloudBoxSettingsSection.cancelKey), findsOneWidget);
  });
}
