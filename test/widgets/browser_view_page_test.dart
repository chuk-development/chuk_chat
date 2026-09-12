import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/ui/expressive/expressive_screen.dart';
import 'package:cowork/widgets/browser_view_page.dart';
import 'package:flutter_rfb/flutter_rfb.dart';

import '../support/fake_relay_controller.dart';

/// Counts the view start/stop the page sends the executor.
class _CountingRelay extends FakeRelayController {
  int starts = 0;
  int stops = 0;

  @override
  Future<void> startBrowserView({String? sessionKey}) async {
    starts++;
    lastSessionKey = sessionKey;
  }

  String? lastSessionKey;

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

  testWidgets('the full-screen controls start below the status-bar inset', (
    tester,
  ) async {
    // A Pixel-class window with a real status bar and a gesture bar.
    const double statusInset = 48;
    const Size window = Size(412, 892);
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: statusInset, bottom: 24);
    addTearDown(tester.view.reset);

    await pumpPage(tester);

    for (final Key key in <Key>[
      const Key('browser_view_close'),
      const Key('browser_view_exit_fullscreen'),
    ]) {
      final Finder target = find.byKey(key);
      expect(target, findsOneWidget, reason: '$key is on screen');
      final Rect box = tester.getRect(target);
      // Below the status bar, never under it.
      expect(
        box.top,
        greaterThanOrEqualTo(statusInset),
        reason: '$key starts below the status inset',
      );
      // And big enough to hit.
      expect(box.height, greaterThanOrEqualTo(MobileLayout.minTouchTarget));
      expect(box.width, greaterThanOrEqualTo(MobileLayout.minTouchTarget));
      expect(box.left, greaterThanOrEqualTo(0));
      expect(box.right, lessThanOrEqualTo(window.width));
    }

    // The error banner keeps clear of the row instead of sitting behind it.
    controller.emit(
      const CoworkRelayBrowserView(status: 'error', message: 'stream died'),
    );
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('stream died')).dy,
      greaterThanOrEqualTo(statusInset + MobileLayout.controlHeight),
    );
  });

  testWidgets('the full-screen toggle keeps the live stream alive', (
    tester,
  ) async {
    await pumpPage(tester);
    controller.emit(const CoworkRelayBrowserView(status: 'started'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final Finder stream = find.byType(RemoteFrameBufferWidget);
    expect(stream, findsOneWidget);
    // The element, not the widget: it owns the RFB isolate and the loopback
    // socket. Rebuilding it used to kill the isolate, close the bridge and
    // latch it shut, so one tap on "full screen" killed the view for good.
    final Element before = tester.element(stream);

    await tester.tap(find.byKey(const Key('browser_view_exit_fullscreen')));
    await tester.pump();
    expect(find.byType(ExpressiveScreen), findsOneWidget);
    expect(identical(tester.element(stream), before), isTrue);

    await tester.tap(find.byKey(const Key('browser_view_enter_fullscreen')));
    await tester.pump();
    expect(find.byType(ExpressiveScreen), findsNothing);
    expect(identical(tester.element(stream), before), isTrue);
  });

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
      await tester.tap(find.byKey(const Key('browser_view_close')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BrowserViewPage), findsNothing);
      expect(controller.stops, 1);
    },
  );
}
