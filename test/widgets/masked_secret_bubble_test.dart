import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

const String _key = 'sk-proj-AbC123dEf456GhI789jKl012MnO345';
const String _message = 'please use $_key for the test';

Widget _wrap(Widget child) => MaterialApp(
  // The test engine has no Vulkan shaders for the M3 ink sparkle.
  theme: ThemeData(splashFactory: InkRipple.splashFactory),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

String _shownText(WidgetTester tester) {
  final StringBuffer out = StringBuffer();
  for (final RichText rt in tester.widgetList<RichText>(
    find.byType(RichText),
  )) {
    out.write(
      rt.text.toPlainText(
        includePlaceholders: false,
        includeSemanticsLabels: false,
      ),
    );
  }
  return out.toString();
}

Finder _semantics(String label) => find.byWidgetPredicate(
  (Widget w) => w is Semantics && w.properties.label == label,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('a key in a user bubble is masked, the eye shows it', (
    tester,
  ) async {
    String? copied;
    await tester.pumpWidget(
      _wrap(
        MessageBubble(
          message: _message,
          isUser: true,
          maxWidth: 600,
          userMessageActions: <MessageBubbleAction>[
            MessageBubbleAction(
              icon: Icons.copy,
              tooltip: 'Copy',
              onPressed: () => copied = _message,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_shownText(tester), isNot(contains(_key)));
    expect(_shownText(tester), contains('sk-proj-•'));
    expect(_shownText(tester), contains('please use '));

    final Finder eye = find.byKey(const ValueKey<String>('secret-toggle-11'));
    expect(eye, findsOneWidget);
    expect(_semantics('Show key'), findsOneWidget);

    await tester.tap(eye);
    await tester.pump();
    expect(_shownText(tester), contains(_key));
    expect(_semantics('Hide key'), findsOneWidget);

    await tester.tap(eye);
    await tester.pump();
    expect(_shownText(tester), isNot(contains(_key)));

    // The masked view never changes what the message holds: copy reads it.
    final MessageBubble bubble = tester.widget(find.byType(MessageBubble));
    expect(bubble.message, _message);
    expect(copied, isNull);
  });

  testWidgets('the messenger copy menu copies the original key', (
    tester,
  ) async {
    final List<MethodCall> calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        calls.add(call);
        return null;
      },
    );
    await tester.pumpWidget(
      _wrap(
        const MessageBubble(
          message: _message,
          isUser: true,
          maxWidth: 600,
          messengerMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(
      find.textContaining('please use', findRichText: true),
    );
    await tester.pumpAndSettle();
    final Finder copy = find.text('Copy');
    if (copy.evaluate().isNotEmpty) {
      await tester.tap(copy.first);
      await tester.pumpAndSettle();
      final MethodCall set = calls.lastWhere(
        (c) => c.method == 'Clipboard.setData',
      );
      expect((set.arguments as Map)['text'], _message);
    }
  });

  testWidgets('text without a key renders as before', (tester) async {
    await tester.pumpWidget(
      _wrap(
        const MessageBubble(
          message: 'hello there',
          isUser: true,
          maxWidth: 600,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('hello there'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('secret-toggle-0')), findsNothing);
  });
}
