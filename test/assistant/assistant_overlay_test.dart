import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/assistant/assistant_overlay.dart';
import 'package:chuk_chat/assistant/assistant_result.dart';
import 'package:chuk_chat/constants.dart';

const Color _accent = Color(0xFFFF7043);
const Color _bg = Color(0xFF1A1113);

Widget _host(Widget child) => MaterialApp(
  theme: buildAppTheme(
    accent: _accent,
    iconFg: const Color(0xFFEDE0E1),
    bg: _bg,
    brightness: Brightness.dark,
  ),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('while only listening the surface shows no panel at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          status: 'Ich höre zu',
          listening: true,
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    // No German status block over the app underneath — the waveform carries
    // the state on its own.
    expect(find.text('CHUK CHAT'), findsNothing);
    expect(find.text('Ich höre zu'), findsNothing);
    expect(find.byType(AssistantWaveform), findsOneWidget);
  });

  testWidgets('the panel appears as soon as the turn produces something', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          status: 'Führe aus …',
          busy: true,
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    expect(find.text('CHUK CHAT'), findsOneWidget);
    expect(find.text('Führe aus …'), findsWidgets);
  });

  testWidgets('while busy the surface shows state, not a half-written turn', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          status: 'Denke nach …',
          transcript: 'wo ist der nächste italiener',
          caption: 'halbfertig',
          busy: true,
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    expect(find.text('Denke nach …'), findsWidgets);
    expect(find.textContaining('wo ist der nächste italiener'), findsNothing);
    expect(find.text('halbfertig'), findsNothing);
  });

  testWidgets('a finished turn quotes the request and shows the answer', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          status: 'Assistent spricht',
          transcript: 'wie spät ist es',
          caption: 'Es ist kurz nach vier.',
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    expect(find.textContaining('wie spät ist es'), findsOneWidget);
    expect(find.text('Es ist kurz nach vier.'), findsOneWidget);
  });

  testWidgets('an error replaces the answer and offers a retry', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          status: 'Fehler',
          caption: 'nicht sichtbar',
          errorText: 'Nicht angemeldet.',
          onMic: () => retried = true,
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    expect(find.text('Nicht angemeldet.'), findsOneWidget);
    expect(find.text('nicht sichtbar'), findsNothing);

    await tester.tap(find.text('Wiederholen'));
    expect(retried, isTrue);
  });

  testWidgets('tool rows show one line per call with its state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          status: 'Führe aus …',
          busy: true,
          tools: const [
            AssistantToolBadge(label: 'Standort', done: true),
            AssistantToolBadge(label: 'Restaurants: Sushi'),
            AssistantToolBadge(label: 'Karte: Kiel', done: true, failed: true),
          ],
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    expect(find.text('Standort'), findsOneWidget);
    expect(find.text('Restaurants: Sushi'), findsOneWidget);
    expect(find.text('Karte: Kiel'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a places result is drawn as a list, not read out as text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          status: 'Assistent spricht',
          caption: 'Drei Treffer, am besten bewertet ist Sakura.',
          card: const AssistantPlacesCard(
            title: 'Sushi',
            places: [
              AssistantPlace(
                name: 'Sakura',
                address: 'Holstenstraße 1, Kiel',
                rating: 4.6,
                reviewCount: 212,
                cuisine: 'Japanisch',
                latitude: 54.32,
                longitude: 10.13,
              ),
              AssistantPlace(name: 'Kaito', address: 'Bergstraße 9, Kiel'),
            ],
          ),
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    expect(find.text('Sushi'), findsOneWidget);
    expect(find.text('Sakura'), findsOneWidget);
    expect(find.text('Kaito'), findsOneWidget);
    expect(find.text('4.6'), findsOneWidget);
    expect(find.text('(212)'), findsOneWidget);
    // Only the place that has coordinates gets the navigation affordance.
    expect(find.byIcon(Icons.navigation_outlined), findsOneWidget);
  });

  testWidgets('web results show title, snippet and host', (tester) async {
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          card: const AssistantLinksCard(
            title: 'wetter kiel',
            links: [
              AssistantLink(
                title: 'Wetter Kiel',
                url: 'https://example.org/kiel/wetter?tag=heute',
                snippet: 'Heute 14 Grad und bewölkt.',
              ),
            ],
          ),
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    expect(find.text('Wetter Kiel'), findsOneWidget);
    expect(find.text('Heute 14 Grad und bewölkt.'), findsOneWidget);
    expect(find.text('example.org'), findsOneWidget);
  });

  testWidgets('the context menu hands the screen to the model', (
    tester,
  ) async {
    var screenTaps = 0;
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          contextOpen: true,
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () => screenTaps++,
        ),
      ),
    );

    await tester.tap(find.text('Bildschirm mitgeben'));
    expect(screenTaps, 1);
    // The surface answers in writing, so there is nothing to mute.
    expect(find.textContaining('vorlesen'), findsNothing);
    expect(find.textContaining('stumm'), findsNothing);
  });

  testWidgets('the surface takes its colours from the running theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          status: 'Ich höre zu',
          transcript: 'test',
          caption: 'antwort',
          listening: true,
          onMic: () {},
          onClose: () {},
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    final quoted = tester.widget<Text>(find.textContaining('test').first);
    final context = tester.element(find.byType(AssistantOverlayView));
    final scheme = Theme.of(context).colorScheme;
    expect(quoted.style?.color, scheme.primary);
    // The old hard-wired assistant blue must not survive anywhere.
    expect(quoted.style?.color, isNot(const Color(0xFFA8C7FA)));
  });

  testWidgets('tapping outside closes the surface', (tester) async {
    var closed = 0;
    await tester.pumpWidget(
      _host(
        AssistantOverlayView(
          onMic: () {},
          onClose: () => closed++,
          onContext: () {},
          onScreen: () {},
        ),
      ),
    );

    await tester.tapAt(const Offset(10, 10));
    expect(closed, 1);
  });
}
