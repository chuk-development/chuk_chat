import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_mode.dart';
import 'package:chuk_chat/widgets/cowork_mode_switcher.dart';

Widget _host({required AppMode mode, required ValueChanged<AppMode> onChanged}) {
  return MaterialApp(
    localizationsDelegates: const [AppLocalizations.delegate],
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('en'),
    home: Scaffold(
      body: CoWorkModeSwitcher(mode: mode, onChanged: onChanged),
    ),
  );
}

void main() {
  testWidgets('renders both Chat and CoWork segments', (tester) async {
    await tester.pumpWidget(_host(mode: AppMode.chat, onChanged: (_) {}));
    await tester.pumpAndSettle();
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('CoWork'), findsOneWidget);
  });

  testWidgets('tapping CoWork reports the new mode', (tester) async {
    AppMode? picked;
    await tester.pumpWidget(
      _host(mode: AppMode.chat, onChanged: (m) => picked = m),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('CoWork'));
    expect(picked, AppMode.cowork);
  });

  testWidgets('tapping the already-selected segment is a no-op', (tester) async {
    AppMode? picked;
    await tester.pumpWidget(
      _host(mode: AppMode.chat, onChanged: (m) => picked = m),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat'));
    expect(picked, isNull);
  });
}
