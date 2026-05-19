// test/services/tour_key_registry_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tour_key_registry.dart';

void main() {
  group('TourKeyRegistry', () {
    setUp(() {
      TourKeyRegistry.instance.clear();
    });

    test('returns the same key for the same slot across calls', () {
      final a = TourKeyRegistry.instance.keyFor(TourSlots.modelDropdown);
      final b = TourKeyRegistry.instance.keyFor(TourSlots.modelDropdown);
      expect(identical(a, b), isTrue);
    });

    test('returns distinct keys for distinct slots', () {
      final a = TourKeyRegistry.instance.keyFor(TourSlots.modelDropdown);
      final b = TourKeyRegistry.instance.keyFor(TourSlots.menuButton);
      expect(identical(a, b), isFalse);
    });

    test('isMounted is false when slot was never attached', () {
      expect(
        TourKeyRegistry.instance.isMounted(TourSlots.chatInput),
        isFalse,
      );
      expect(
        TourKeyRegistry.instance.contextFor(TourSlots.chatInput),
        isNull,
      );
    });

    testWidgets(
      'isMounted is true once a widget attaches the key',
      (tester) async {
        final key = TourKeyRegistry.instance.keyFor(TourSlots.chatInput);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KeyedSubtree(
                key: key,
                child: const SizedBox(width: 100, height: 50),
              ),
            ),
          ),
        );
        expect(
          TourKeyRegistry.instance.isMounted(TourSlots.chatInput),
          isTrue,
        );
        expect(
          TourKeyRegistry.instance.contextFor(TourSlots.chatInput),
          isNotNull,
        );
      },
    );
  });
}
