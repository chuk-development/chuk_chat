// The maintenance screen: the shell is not built while the chat rewrite
// runs, the two bars show their counts, and a failure offers Retry and
// Continue. Localized in every app language.

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/l10n/strings_de.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/l10n/strings_es.dart';
import 'package:chuk_chat/l10n/strings_fr.dart';
import 'package:chuk_chat/l10n/strings_pt.dart';
import 'package:chuk_chat/services/chat_payload_migration_service.dart';
import 'package:chuk_chat/widgets/chat_maintenance_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: child,
);

void main() {
  final controller = ChatMaintenanceController.instance;
  tearDown(controller.reset);

  testWidgets('while running, the shell is not built and the bars count', (
    tester,
  ) async {
    controller.debugShow(
      ChatMaintenancePhase.running,
      progress: const ChatMaintenanceProgress(
        migrated: 7,
        verified: 3,
        total: 12,
      ),
    );
    await tester.pumpWidget(
      _app(
        ChatMaintenanceGate(controller: controller, child: const Text('SHELL')),
      ),
    );
    await tester.pump();

    expect(find.text('SHELL'), findsNothing);
    expect(
      find.text('Please do not close the app. Your data is being rewritten.'),
      findsOneWidget,
    );
    expect(find.text('7 of 12'), findsOneWidget);
    expect(find.text('3 of 12'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
  });

  testWidgets('a failure offers Retry and Continue; Continue opens the app', (
    tester,
  ) async {
    controller.debugShow(
      ChatMaintenancePhase.failed,
      failure: ChatMaintenanceFailure('local', StateError('x'), restored: true),
    );
    await tester.pumpWidget(
      _app(
        ChatMaintenanceGate(controller: controller, child: const Text('SHELL')),
        locale: const Locale('de'),
      ),
    );
    await tester.pump();

    expect(find.text('Erneut versuchen'), findsOneWidget);
    expect(find.text('Fortfahren'), findsOneWidget);
    await tester.tap(find.text('Fortfahren'));
    await tester.pumpAndSettle();
    expect(find.text('SHELL'), findsOneWidget);
  });

  test('every language has every maintenance string', () {
    const keys = [
      'maintenanceTitle',
      'maintenanceBody',
      'maintenanceMigrating',
      'maintenanceVerifying',
      'maintenanceCount',
      'maintenanceFailedTitle',
      'maintenanceFailedBody',
      'maintenanceContinue',
    ];
    for (final strings in [
      stringsEn,
      stringsDe,
      stringsEs,
      stringsFr,
      stringsPt,
    ]) {
      for (final key in keys) {
        expect(strings[key], isNotEmpty, reason: key);
      }
      expect(strings['maintenanceCount'], contains('{n}'));
      expect(strings['maintenanceCount'], contains('{total}'));
    }
  });
}
