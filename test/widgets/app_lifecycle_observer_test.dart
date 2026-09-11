import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/widgets/app_lifecycle_observer.dart';

/// `AppLifecycleService.handleLifecycleState` was called by NOBODY in
/// `app/lib`: no widget observed the binding at app level, so every resume and
/// pause callback the imported chat UI registers was dead code.
void main() {
  testWidgets('the observer forwards resume and pause', (tester) async {
    final List<AppLifecycleState> seen = <AppLifecycleState>[];
    await tester.pumpWidget(
      AppLifecycleObserver(onState: seen.add, child: const SizedBox.shrink()),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(
      seen,
      containsAllInOrder(<AppLifecycleState>[
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
      ]),
    );
  });

  testWidgets('it stops listening once it is gone', (tester) async {
    final List<AppLifecycleState> seen = <AppLifecycleState>[];
    await tester.pumpWidget(
      AppLifecycleObserver(onState: seen.add, child: const SizedBox.shrink()),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    seen.clear();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(seen, isEmpty);
  });
}
