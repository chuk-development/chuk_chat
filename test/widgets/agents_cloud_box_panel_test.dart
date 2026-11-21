// The cloud computer setup screen and the settings row (CHAT-164).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_cloud_box_api.dart';
import 'package:chuk_chat/services/agents/agents_cloud_box_flow.dart';
import 'package:chuk_chat/widgets/agents_cloud_box_panel.dart';
import 'package:chuk_chat/widgets/agents_cloud_box_settings_section.dart';

class _Api implements AgentsCloudBoxApi {
  _Api(this.answer);

  final Object answer;

  @override
  Future<AgentsCloudBoxStatus> fetch() async {
    if (answer is AgentsCloudBoxStatus) return answer as AgentsCloudBoxStatus;
    throw answer;
  }

  @override
  Future<AgentsCloudBoxStatus> request(String pairingToken) => fetch();
}

Widget _app(Widget child) => MaterialApp(
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    DefaultMaterialLocalizations.delegate,
    DefaultWidgetsLocalizations.delegate,
  ],
  home: Scaffold(body: child),
);

void main() {
  testWidgets('setting up: calm title, a loader, the self-host way out', (
    WidgetTester tester,
  ) async {
    var own = 0;
    await tester.pumpWidget(
      _app(
        AgentsCloudBoxPanel(
          phase: AgentsCloudBoxPhase.settingUp,
          onUseOwnComputer: () => own++,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Setting up your cloud computer'), findsOneWidget);
    expect(find.byKey(AgentsCloudBoxPanel.loaderKey), findsOneWidget);
    expect(find.byKey(AgentsCloudBoxPanel.retryKey), findsNothing);
    await tester.tap(find.byKey(AgentsCloudBoxPanel.ownComputerKey));
    expect(own, 1);
  });

  testWidgets('German: the strings come from the localization', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (BuildContext context) => Localizations.override(
            context: context,
            locale: const Locale('de'),
            delegates: const <LocalizationsDelegate<Object>>[
              AppLocalizations.delegate,
            ],
            child: const AgentsCloudBoxPanel(phase: AgentsCloudBoxPhase.slow),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Dein Cloud-Computer wird noch vorbereitet'),
      findsOneWidget,
    );
  });

  testWidgets('suspended: billing button, no loader', (
    WidgetTester tester,
  ) async {
    var billing = 0;
    await tester.pumpWidget(
      _app(
        AgentsCloudBoxPanel(
          phase: AgentsCloudBoxPhase.suspended,
          onOpenBilling: () => billing++,
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(AgentsCloudBoxPanel.loaderKey), findsNothing);
    await tester.tap(find.byKey(AgentsCloudBoxPanel.billingKey));
    expect(billing, 1);
  });

  testWidgets('failed: retry button', (WidgetTester tester) async {
    var retries = 0;
    await tester.pumpWidget(
      _app(
        AgentsCloudBoxPanel(
          phase: AgentsCloudBoxPhase.failed,
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(AgentsCloudBoxPanel.retryKey));
    expect(retries, 1);
  });

  testWidgets('narrow and large text: no overflow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: _app(
          AgentsCloudBoxPanel(
            phase: AgentsCloudBoxPhase.slow,
            onUseOwnComputer: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  group('settings section', () {
    testWidgets('running: state and last backup', (WidgetTester tester) async {
      await tester.pumpWidget(
        _app(
          AgentsCloudBoxSettingsSection(
            api: _Api(
              AgentsCloudBoxStatus(
                state: AgentsCloudBoxState.running,
                lastBackupAt: DateTime(2026, 11, 20, 3),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(AgentsCloudBoxSettingsSection.rowKey), findsOneWidget);
      expect(find.textContaining('Running'), findsOneWidget);
      expect(find.textContaining('Last backup:'), findsOneWidget);
    });

    testWidgets('none or 404: nothing at all', (WidgetTester tester) async {
      for (final Object answer in <Object>[
        AgentsCloudBoxStatus.none,
        const AgentsCloudBoxException(404, 'http_404'),
      ]) {
        await tester.pumpWidget(
          _app(
            AgentsCloudBoxSettingsSection(key: UniqueKey(), api: _Api(answer)),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(find.byKey(AgentsCloudBoxSettingsSection.rowKey), findsNothing);
        expect(find.text('Cloud computer'), findsNothing);
      }
    });
  });
}
