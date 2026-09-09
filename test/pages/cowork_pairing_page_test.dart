import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/pages/cowork_pairing_page.dart';
import 'package:cowork/services/cowork/cowork_pairing_uri.dart';

/// A stand-in camera. It renders a marker instead of a preview and exposes the
/// two things a real scanner ever tells the screen: a code was read, or the
/// camera cannot be used.
class _FakeCamera {
  ValueChanged<String>? onCode;
  ValueChanged<String>? onUnavailable;
  int builds = 0;

  Widget build(
    BuildContext context, {
    required ValueChanged<String> onCode,
    required ValueChanged<String> onUnavailable,
  }) {
    builds++;
    this.onCode = onCode;
    this.onUnavailable = onUnavailable;
    return const ColoredBox(
      key: ValueKey<String>('fake-camera'),
      color: Colors.black,
    );
  }
}

void main() {
  const String channel = 'k7m2p9q4w8r3t6y1u5i0o2a7s4d9f3g6h1j8k5l2z7x4c9v6b3';
  const String uri = 'cowork://pair?c=$channel&k=428913';

  /// Puts the screen on its own, for the cases that only look at what it shows.
  Future<void> pump(
    WidgetTester tester, {
    required bool cameraAvailable,
    _FakeCamera? camera,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CoworkPairingPage(
          cameraAvailable: cameraAvailable,
          qrViewBuilder: camera?.build,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('on a phone the screen opens with the camera', (tester) async {
    final camera = _FakeCamera();
    await pump(tester, cameraAvailable: true, camera: camera);

    expect(find.byKey(const ValueKey<String>('fake-camera')), findsOneWidget);
    expect(camera.builds, greaterThan(0));
    expect(
      find.text('Point the camera at the code on your computer.'),
      findsOneWidget,
    );
    // The fallback is always one tap away.
    expect(
      find.byKey(const ValueKey<String>('cowork-pairing-use-code')),
      findsOneWidget,
    );
    // No jargon on the default path.
    expect(find.textContaining('URL'), findsNothing);
    expect(find.textContaining('port'), findsNothing);
  });

  testWidgets('a scanned invite closes the screen with it', (tester) async {
    final camera = _FakeCamera();
    CoworkPairingInvite? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                got = await Navigator.of(context).push<CoworkPairingInvite>(
                  MaterialPageRoute<CoworkPairingInvite>(
                    builder: (_) => CoworkPairingPage(
                      cameraAvailable: true,
                      qrViewBuilder: camera.build,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    camera.onCode!(uri);
    await tester.pumpAndSettle();

    expect(got, isNotNull);
    expect(got!.pairingChannel, channel);
    expect(got!.pairingCode, '$channel-428913');
  });

  testWidgets('a stray QR code is ignored, the camera stays up', (
    tester,
  ) async {
    final camera = _FakeCamera();
    await pump(tester, cameraAvailable: true, camera: camera);

    camera.onCode!('https://example.test/a-poster');
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('fake-camera')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('cowork-pairing-message')),
      findsOneWidget,
    );
    // The scanned text is never echoed back at the user.
    expect(find.textContaining('example.test'), findsNothing);
  });

  testWidgets('a refused camera falls through to the code field', (
    tester,
  ) async {
    final camera = _FakeCamera();
    await pump(tester, cameraAvailable: true, camera: camera);

    camera.onUnavailable!(
      'This app is not allowed to use the camera. Enter the code instead.',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('fake-camera')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('cowork-pairing-code-field')),
      findsOneWidget,
    );
    expect(
      find.textContaining('not allowed to use the camera'),
      findsOneWidget,
    );
  });

  testWidgets('"enter the code instead" is the same result as a scan', (
    tester,
  ) async {
    final camera = _FakeCamera();
    CoworkPairingInvite? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                got = await Navigator.of(context).push<CoworkPairingInvite>(
                  MaterialPageRoute<CoworkPairingInvite>(
                    builder: (_) => CoworkPairingPage(
                      cameraAvailable: true,
                      qrViewBuilder: camera.build,
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('cowork-pairing-use-code')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('cowork-pairing-code-field')),
      uri,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('cowork-pairing-connect')),
    );
    await tester.pumpAndSettle();

    expect(got, isNotNull);
    expect(got!.pairingCode, '$channel-428913');
  });

  testWidgets('an incomplete code says what to do, in one sentence', (
    tester,
  ) async {
    await pump(tester, cameraAvailable: false);

    await tester.enterText(
      find.byKey(const ValueKey<String>('cowork-pairing-code-field')),
      'nonsense',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('cowork-pairing-connect')),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'That code is not complete. Copy the whole line your computer shows.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('on a desktop the code field is what opens', (tester) async {
    await pump(tester, cameraAvailable: false);

    expect(
      find.byKey(const ValueKey<String>('cowork-pairing-code-field')),
      findsOneWidget,
    );
    // Nothing to switch to: there is no camera worth offering.
    final camera = tester.widget<TextButton>(
      find.byKey(const ValueKey<String>('cowork-pairing-use-camera')),
    );
    expect(camera.onPressed, isNull);
  });
}
