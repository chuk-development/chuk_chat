import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/ui/expressive/expressive_screen.dart';
import 'package:cowork/widgets/browser_view_page.dart';

import '../support/fake_relay_controller.dart';

/// Counts the view start/stop the page sends the executor.
class _CountingRelay extends FakeRelayController {
  int starts = 0;
  int stops = 0;

  @override
  Future<void> startBrowserView() async => starts++;

  @override
  Future<void> stopBrowserView() async => stops++;
}

void main() {
  late _CountingRelay controller;

  setUp(() => controller = _CountingRelay());
  tearDown(() async => controller.dispose());

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: BrowserViewPage(controller: controller)),
    );
    await tester.pump();
  }

  testWidgets(
    'asks the executor for the stream and waits for its started event',
    (tester) async {
      await pumpPage(tester);
      expect(controller.starts, 1);
      expect(find.byType(ExpressiveScreen), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byKey(const Key('browser_view_exit_fullscreen')));
      await tester.pump();
      expect(find.text('connecting…'), findsOneWidget);

      controller.emit(
        const CoworkRelayBrowserView(
          status: 'started',
          message: 'no page open yet — ask the agent to open a browser',
        ),
      );
      await tester.pump();
      expect(find.textContaining('no page open yet'), findsOneWidget);

      controller.emit(
        const CoworkRelayBrowserView(
          status: 'error',
          message: 'vnc bridge failed',
        ),
      );
      await tester.pump();
      expect(find.text('vnc bridge failed'), findsOneWidget);
    },
  );

  testWidgets(
    'full screen hides the chrome and a floating button brings it back',
    (tester) async {
      await pumpPage(tester);
      expect(find.byType(ExpressiveScreen), findsNothing);
      expect(find.text('Agent browser'), findsNothing);
      expect(find.text('connecting…'), findsNothing);
      expect(
        find.byKey(const Key('browser_view_exit_fullscreen')),
        findsOneWidget,
      );

      // An error still surfaces in full screen: never a silent black screen.
      controller.emit(
        const CoworkRelayBrowserView(status: 'error', message: 'stream died'),
      );
      await tester.pump();
      expect(find.text('stream died'), findsOneWidget);

      await tester.tap(find.byKey(const Key('browser_view_exit_fullscreen')));
      await tester.pump();
      expect(find.byType(ExpressiveScreen), findsOneWidget);
      expect(find.text('Agent browser'), findsOneWidget);
      expect(find.text('stream died'), findsOneWidget);
    },
  );

  testWidgets(
    'open() pushes a full-screen dialog route; leaving stops the stream',
    (tester) async {
      late BuildContext hostContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              hostContext = context;
              return const Scaffold(body: Text('home'));
            },
          ),
        ),
      );
      BrowserViewPage.open(hostContext, controller);
      // Not pumpAndSettle: the page shows an indeterminate spinner until the
      // executor's `started` event, and that animation never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BrowserViewPage), findsOneWidget);
      final route = ModalRoute.of(tester.element(find.byType(BrowserViewPage)));
      expect((route as MaterialPageRoute).fullscreenDialog, isTrue);
      expect(controller.starts, 1);

      // A full-screen dialog closes with an X, not a back arrow.
      await tester.tap(find.byType(CloseButton));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BrowserViewPage), findsNothing);
      expect(controller.stops, 1);
    },
  );
}
