// test/services/onboarding_tour_controller_test.dart
//
// Smoke tests for the rewritten OnboardingTourController. We can't easily
// drive the full state machine in a widget test (it relies on the navigator
// observer firing for pushed PopupRoutes and SettingsPage) but we can
// confirm:
//   * the controller is inactive by default
//   * cancel() on a never-started controller is safe
//   * the static TourNavigatorObserver swallows events when no tour is
//     attached
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/onboarding_tour_controller.dart';
import 'package:chuk_chat/services/tour_key_registry.dart';

void main() {
  group('OnboardingTourController', () {
    setUp(() {
      TourKeyRegistry.instance.clear();
      // Defensive — make sure a previous test didn't leave the tour active.
      OnboardingTourController.instance.cancel();
    });

    test('isActive is false out of the box', () {
      expect(OnboardingTourController.instance.isActive, isFalse);
    });

    test('cancel() on an inactive controller is a no-op', () {
      OnboardingTourController.instance.cancel();
      expect(OnboardingTourController.instance.isActive, isFalse);
    });

    test('navigatorObserver does not throw when no tour is active', () {
      final observer = OnboardingTourController.navigatorObserver;
      // didPush / didPop with detached handlers should be silent.
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      observer.didPush(route, null);
      observer.didPop(route, null);
      expect(true, isTrue); // No throws.
    });
  });
}
