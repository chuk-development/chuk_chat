import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/regen_variant_seed.dart';

// Minimal host that mixes in the shared seed logic and lets a test drive the
// one hook it needs (which chat is visible). No app/UI needed.
class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with RegenVariantSeedMixin<_Host> {
  String? activeChat;

  @override
  String? get variantActiveChatId => activeChat;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<_HostState> _pump(WidgetTester tester) async {
  await tester.pumpWidget(const _Host());
  return tester.state<_HostState>(find.byType(_Host));
}

List<Map<String, dynamic>> _seed() => <Map<String, dynamic>>[
  <String, dynamic>{'text': 'old answer'},
];

void main() {
  group('foldRegenVariantOnto (foreground)', () {
    testWidgets('folds onto the armed message and appends the new variant', (
      tester,
    ) async {
      final s = await _pump(tester);
      s.armVariantSeed(_seed(), 'm1');

      final msg = <String, String>{'messageId': 'm1', 'text': 'new answer'};
      expect(s.foldRegenVariantOnto(msg), isTrue);

      final variants = jsonDecode(msg['variants']!) as List;
      expect(variants.length, 2); // old seed + new
      expect(msg['activeVariant'], '1'); // new is active
    });

    testWidgets('skips when the messageId does not match', (tester) async {
      final s = await _pump(tester);
      s.armVariantSeed(_seed(), 'm1');

      final msg = <String, String>{'messageId': 'other', 'text': 'new'};
      expect(s.foldRegenVariantOnto(msg), isFalse);
      expect(msg['variants'], isNull);
    });

    testWidgets('skips the Thinking placeholder', (tester) async {
      final s = await _pump(tester);
      s.armVariantSeed(_seed(), 'm1');
      expect(
        s.foldRegenVariantOnto({'messageId': 'm1', 'text': 'Thinking...'}),
        isFalse,
      );
    });

    testWidgets('arming with a null seed disarms', (tester) async {
      final s = await _pump(tester);
      s.armVariantSeed(null, 'm1');
      expect(
        s.foldRegenVariantOnto({'messageId': 'm1', 'text': 'new'}),
        isFalse,
      );
    });
  });

  group('stash / restore across a chat switch', () {
    testWidgets('stashes the armed seed on switch, then restores on return', (
      tester,
    ) async {
      final s = await _pump(tester);
      s.activeChat = 'A';
      s.armVariantSeed(_seed(), 'mA');

      // Leave chat A: the armed seed moves to the stash and the visible-chat
      // fields are cleared (the foreground fold no longer folds).
      s.stashVariantSeedForBackground();
      expect(
        s.foldRegenVariantOnto({'messageId': 'mA', 'text': 'new'}),
        isFalse,
      );

      // Return to A: the seed is re-armed and the foreground fold works again.
      s.activeChat = 'A';
      s.restoreVariantSeedForChat('A');
      final msg = <String, String>{'messageId': 'mA', 'text': 'new'};
      expect(s.foldRegenVariantOnto(msg), isTrue);
      expect((jsonDecode(msg['variants']!) as List).length, 2);
    });

    testWidgets('stashes without a liveness check (regenerate await race)', (
      tester,
    ) async {
      // A regenerate arms the seed and then awaits before streaming starts. A
      // switch inside that window must still preserve the seed, so the stash
      // does not depend on the chat already looking "live".
      final s = await _pump(tester);
      s.activeChat = 'A';
      s.armVariantSeed(_seed(), 'mA');

      s.stashVariantSeedForBackground();
      // The seed was stashed, so the background completion can still fold it.
      final row = <String, String>{'messageId': 'mA', 'text': 'new'};
      expect(s.foldBackgroundVariantOnto('A', row), isTrue);
      expect((jsonDecode(row['variants']!) as List).length, 2);
    });

    testWidgets('a switch with no armed seed stashes nothing', (tester) async {
      final s = await _pump(tester);
      s.activeChat = 'A'; // no regenerate armed

      s.stashVariantSeedForBackground();
      expect(
        s.foldBackgroundVariantOnto('A', {'messageId': 'mA', 'text': 'new'}),
        isFalse,
      );
    });
  });

  group('foldBackgroundVariantOnto', () {
    testWidgets('folds from the stash and evicts on success', (tester) async {
      final s = await _pump(tester);
      s.activeChat = 'A';
      s.armVariantSeed(_seed(), 'mA');
      s.stashVariantSeedForBackground();

      final row = <String, String>{'messageId': 'mA', 'text': 'new'};
      expect(s.foldBackgroundVariantOnto('A', row), isTrue);
      expect((jsonDecode(row['variants']!) as List).length, 2);

      // One-shot: the stash was evicted, so a second call does nothing.
      expect(
        s.foldBackgroundVariantOnto('A', {'messageId': 'mA', 'text': 'x'}),
        isFalse,
      );
    });

    testWidgets('stamps a missing messageId (storage-rebuild fallback)', (
      tester,
    ) async {
      final s = await _pump(tester);
      s.activeChat = 'A';
      s.armVariantSeed(_seed(), 'mA');
      s.stashVariantSeedForBackground();

      // The rebuilt row has no messageId; the fold must stamp it so its id
      // guard matches, or the only archived answer is lost.
      final row = <String, String>{'text': 'new'};
      expect(s.foldBackgroundVariantOnto('A', row), isTrue);
      expect(row['messageId'], 'mA');
      expect(row['variants'], isNotNull);
    });

    testWidgets('keeps the stash when the fold is skipped', (tester) async {
      final s = await _pump(tester);
      s.activeChat = 'A';
      s.armVariantSeed(_seed(), 'mA');
      s.stashVariantSeedForBackground();

      // A skipped fold (still the placeholder) must NOT evict the stash.
      expect(
        s.foldBackgroundVariantOnto('A', {
          'messageId': 'mA',
          'text': 'Thinking...',
        }),
        isFalse,
      );
      // A real fold afterwards still finds the stash.
      final row = <String, String>{'messageId': 'mA', 'text': 'new'};
      expect(s.foldBackgroundVariantOnto('A', row), isTrue);
      expect(row['variants'], isNotNull);
    });
  });
}
