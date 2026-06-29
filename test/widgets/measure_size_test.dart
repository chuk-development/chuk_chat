import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/widgets/measure_size.dart';

void main() {
  testWidgets('reports the child size after layout', (tester) async {
    Size? reported;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: MeasureSize(
            onChange: (size) => reported = size,
            child: const SizedBox(width: 120, height: 48),
          ),
        ),
      ),
    );
    await tester.pump(); // flush the post-frame callback

    expect(reported, const Size(120, 48));
  });

  testWidgets('fires again only when the size actually changes', (tester) async {
    final List<Size> reports = [];
    double height = 40;
    late StateSetter setHeight;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: StatefulBuilder(
            builder: (context, setState) {
              setHeight = setState;
              return MeasureSize(
                onChange: reports.add,
                child: SizedBox(width: 100, height: height),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(reports, [const Size(100, 40)]);

    // Same size on rebuild -> no new report.
    setHeight(() {});
    await tester.pump();
    expect(reports, [const Size(100, 40)]);

    // Grow -> exactly one new report.
    setHeight(() => height = 90);
    await tester.pump();
    expect(reports, [const Size(100, 40), const Size(100, 90)]);
  });
}
