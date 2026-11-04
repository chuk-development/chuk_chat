import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/message_bubble.dart';

void main() {
  test('a 1:10 strip is drawn in a 1:4 box', () {
    final Size box = singleImageBox(maxWidth: 200, aspectRatio: 1 / 10);
    expect(box.width, 200);
    expect(box.height, 800);
    expect(box.width / box.height, closeTo(1 / 4, 1e-9));
  });

  test('a 10:1 panorama is drawn in a 4:1 box', () {
    final Size box = singleImageBox(maxWidth: 400, aspectRatio: 10);
    expect(box, const Size(400, 100));
  });

  test('a ratio inside the range is kept', () {
    expect(
      singleImageBox(maxWidth: 300, aspectRatio: 1.5),
      const Size(300, 200),
    );
  });

  test('a height cap narrows the box and keeps the ratio', () {
    final Size box = singleImageBox(
      maxWidth: 400,
      aspectRatio: 1 / 10,
      maxHeight: 760,
    );
    expect(box.height, 760);
    expect(box.width, 190);
  });
}
