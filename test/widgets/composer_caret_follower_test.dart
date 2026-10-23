import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/composer_caret_follower.dart';

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;
  late ScrollController scrollController;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
    scrollController = ScrollController();
  });

  tearDown(() {
    controller.dispose();
    focusNode.dispose();
    scrollController.dispose();
  });

  Future<void> pumpField(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              scrollController: scrollController,
              minLines: 1,
              maxLines: 4,
            ),
          ),
        ),
      ),
    );
  }

  final String longText = List<String>.generate(
    40,
    (int i) => 'line $i',
  ).join('\n');

  testWidgets('a programmatic paste leaves the field at the top without it', (
    WidgetTester tester,
  ) async {
    await pumpField(tester);
    controller.value = TextEditingValue(
      text: longText,
      selection: TextSelection.collapsed(offset: longText.length),
    );
    await tester.pumpAndSettle();
    expect(scrollController.offset, 0);
  });

  testWidgets('follows the caret to the end of a long programmatic paste', (
    WidgetTester tester,
  ) async {
    await pumpField(tester);
    final ComposerCaretFollower follower = ComposerCaretFollower(
      controller: controller,
      focusNode: focusNode,
      scrollController: scrollController,
    );
    addTearDown(follower.dispose);

    controller.value = TextEditingValue(
      text: longText,
      selection: TextSelection.collapsed(offset: longText.length),
    );
    await tester.pumpAndSettle();

    expect(scrollController.offset, greaterThan(0));
    expect(
      scrollController.offset,
      closeTo(scrollController.position.maxScrollExtent, 1),
    );
  });

  testWidgets('scrolls to the end when the text is set without a caret', (
    WidgetTester tester,
  ) async {
    await pumpField(tester);
    final ComposerCaretFollower follower = ComposerCaretFollower(
      controller: controller,
      focusNode: focusNode,
      scrollController: scrollController,
    );
    addTearDown(follower.dispose);

    controller.text = longText;
    await tester.pumpAndSettle();

    expect(
      scrollController.offset,
      closeTo(scrollController.position.maxScrollExtent, 1),
    );
  });

  testWidgets('leaves the scroll alone when only the selection moves', (
    WidgetTester tester,
  ) async {
    controller.text = longText;
    await pumpField(tester);
    final ComposerCaretFollower follower = ComposerCaretFollower(
      controller: controller,
      focusNode: focusNode,
      scrollController: scrollController,
    );
    addTearDown(follower.dispose);

    controller.selection = TextSelection.collapsed(offset: longText.length);
    await tester.pumpAndSettle();

    expect(scrollController.offset, 0);
  });
}
