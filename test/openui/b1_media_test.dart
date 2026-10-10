// Widget tests for the B1 media: Image, ImageBlock, ImageGallery.
// The test host answers every HTTP request with 400, so a network
// image ends in its error tile; that is the path the tests check.
// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/image_viewer.dart';

import 'openui_test_helper.dart';

void main() {
  testWidgets('Image holds a 3:2 box and shows the alt on failure', (
    tester,
  ) async {
    await pumpOpenUi(
      tester,
      'root = Card([a, b, c])\n'
      'a = Image("A red bike", "https://example.com/bike.jpg")\n'
      'b = Image("Only alt")\n'
      'c = Image("Bad scheme", "file:///etc/passwd")\n',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    // The test column is 420 wide: 420 x 280 is 3:2.
    final box = tester.getSize(find.bySemanticsLabel('A red bike').first);
    expect(box.width / box.height, closeTo(1.5, 0.01));
    expect(find.text('Only alt'), findsOneWidget);
    expect(find.text('Bad scheme'), findsOneWidget);
  });

  testWidgets('ImageBlock keeps its height and skips an empty src', (
    tester,
  ) async {
    await pumpOpenUi(
      tester,
      'root = Card([a, b, c])\n'
      'a = ImageBlock("https://example.com/x.png", "A chart")\n'
      'b = ImageBlock("")\n'
      'c = ImageBlock(12)\n',
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
    final sized = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .where((s) => s.height == 240);
    // The URL block and the number block (a bad source) keep 240.
    expect(sized, hasLength(2));
  });

  testWidgets('ImageGallery lays out a grid at phone width', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([ImageGallery([{src: "https://e.com/1.jpg", alt: "One"}, '
      '{src: "https://e.com/2.jpg"}, {src: "https://e.com/3.jpg", '
      'details: "d"}, {alt: "no src"}, "junk"])])\n',
    );
    expect(tester.takeException(), isNull);
    // Three images with a source: three columns, one row.
    final tiles = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .where((s) => s.width != null && s.width == s.height && s.width! > 50)
        .toList();
    expect(tiles, hasLength(3));
  });

  testWidgets('a tap on a gallery tile opens the image viewer', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([ImageGallery([{src: "https://e.com/1.jpg"}, '
      '{src: "https://e.com/2.jpg"}])])\n',
    );
    await tester.tap(find.byType(ClipRRect).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ImageViewer), findsOneWidget);
    final viewer = tester.widget<ImageViewer>(find.byType(ImageViewer));
    expect(viewer.allImages, ['https://e.com/1.jpg', 'https://e.com/2.jpg']);
    expect(viewer.initialIndex, 1);
  });

  testWidgets('bad gallery input does not throw', (tester) async {
    await pumpOpenUi(
      tester,
      'root = Card([ImageGallery(), ImageGallery("x"), ImageGallery([])])\n',
    );
    expect(tester.takeException(), isNull);
  });
}
