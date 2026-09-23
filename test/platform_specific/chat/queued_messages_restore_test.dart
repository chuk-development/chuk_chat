// Cancelling the queue puts every queued message back into the composer.
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';

void main() {
  test('no follow-ups: the pending message alone, as upstream', () {
    expect(queuedMessagesForComposer('only one', const <String>[]), 'only one');
  });

  test('the pending message and every follow-up, in the order typed', () {
    expect(
      queuedMessagesForComposer('first', const <String>['second', 'third']),
      'first\n\nsecond\n\nthird',
    );
  });
}
