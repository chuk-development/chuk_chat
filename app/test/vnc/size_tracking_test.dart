// flutter_rfb's SizeTrackingWidget (CoWork fork) must follow its child's size
// across rebuilds, not just measure once — a framebuffer resize otherwise
// leaves the tap/wheel coordinate mapping stale.
import 'package:flutter/widgets.dart';
import 'package:flutter_rfb/src/child_size_notifier_widget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('re-measures after the child changes size', (tester) async {
    final notifier = ValueNotifier<Size>(Size.zero);
    Widget build(double w, double h) => Center(
          child: SizeTrackingWidget(
            sizeValueNotifier: notifier,
            child: SizedBox(width: w, height: h),
          ),
        );
    await tester.pumpWidget(build(100, 50));
    await tester.pump();
    expect(notifier.value, const Size(100, 50));

    await tester.pumpWidget(build(200, 80));
    await tester.pump();
    expect(notifier.value, const Size(200, 80));
  });
}
