import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/link_preview_service.dart';
import 'package:chuk_chat/widgets/link_preview_card.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

// 1x1 transparent PNG.
final Uint8List _png = Uint8List.fromList(<int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);

Widget _host(Widget child, {double width = 400}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

Widget _markdown(String text) => _host(
  MarkdownMessage(
    text: text,
    textColor: Colors.black,
    backgroundColor: Colors.white,
    wrapWithSelectionArea: false,
  ),
  width: 600,
);

Map<String, dynamic> _card(String url, {String title = 'Card title'}) =>
    <String, dynamic>{
      'url': url,
      'host': Uri.parse(url).host,
      'title': title,
      'description': 'What the page is about.',
      'site_name': 'Hugging Face',
      'icon': 'https://icons.test/i.png',
    };

void main() {
  setUp(() {
    LinkPreviewService.debugReset();
    LinkPreviewService.debugSkipPersistentCache = true;
    LinkPreviewService.debugFetchImage = (String url) async => _png;
    LinkPreviewService.debugFetchCard = (String url) async => _card(url);
  });
  tearDown(() {
    LinkPreviewHover.hide();
    LinkPreviewService.debugReset();
  });

  testWidgets('compact card: title · site, description, footer', (
    tester,
  ) async {
    final LinkPreview p = LinkPreview.fromJson(
      _card('https://huggingface.co/owensong/Inflect-Mini-v3'),
    )!;
    await tester.pumpWidget(_host(LinkPreviewCard(preview: p)));
    await tester.pumpAndSettle();
    expect(find.text('Card title · Hugging Face'), findsOneWidget);
    expect(find.text('What the page is about.'), findsOneWidget);
    expect(
      find.text('huggingface.co/owensong/Inflect-Mini-v3'),
      findsOneWidget,
    );
    expect(find.byType(AspectRatio), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card with og:image draws the picture on top', (tester) async {
    final LinkPreview p = LinkPreview.fromJson(<String, dynamic>{
      ..._card('https://arxiv.org/abs/2611.14043', title: 'ESDCodec'),
      'image': 'https://arxiv.test/card.png',
    })!;
    await tester.pumpWidget(_host(LinkPreviewCard(preview: p)));
    await tester.pumpAndSettle();
    expect(find.byType(AspectRatio), findsOneWidget);
    // With a picture the title stands alone.
    expect(find.text('ESDCodec'), findsOneWidget);
  });

  testWidgets('long texts at 300 px and 1.3 text scale do not overflow', (
    tester,
  ) async {
    final LinkPreview p = LinkPreview.fromJson(<String, dynamic>{
      ..._card(
        'https://example.com/a/very/long/path/that/never/ends',
        title: 'A very long title that keeps going and going and going on',
      ),
      'description': 'word ' * 80,
    })!;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: _host(LinkPreviewCard(preview: p), width: 300),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('favicon shows the glyph, then the site icon', (tester) async {
    await tester.pumpWidget(
      _host(
        const Center(child: LinkFavicon(url: 'https://a.test/x', size: 16)),
      ),
    );
    expect(find.byType(Image), findsNothing);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.getSize(find.byType(LinkFavicon)), const Size(16, 16));
  });

  testWidgets('favicon keeps the glyph when there is no card', (tester) async {
    LinkPreviewService.debugFetchCard = (String url) async => <String, dynamic>{
      'url': url,
      'empty': true,
    };
    await tester.pumpWidget(
      _host(const LinkFavicon(url: 'https://a.test/x', size: 16)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('markdown link: icon in front, short name for a bare url, '
      'no card under the message', (tester) async {
    await tester.pumpWidget(
      _markdown(
        'See [Inflect Mini v3](https://huggingface.co/owensong/Inflect-Mini-v3) '
        'and https://www.example.com/docs/page/ for more.',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LinkFavicon), findsNWidgets(2));
    expect(find.byType(LinkPreviewCard), findsNothing);
    final String shown = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((RichText r) => r.text.toPlainText())
        .join('\n');
    expect(shown, contains('Inflect Mini v3'));
    expect(shown, contains('example.com/docs/page'));
    expect(shown, isNot(contains('https://www.example.com')));
  });

  testWidgets('favicon is one text line high and centred on the line', (
    tester,
  ) async {
    await tester.pumpWidget(_markdown('[Inflect Mini v3](https://hf.test/x)'));
    await tester.pumpAndSettle();
    final Rect icon = tester.getRect(find.byType(LinkFavicon));
    final RichText rich = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((RichText r) => r.text.toPlainText().contains('Inflect'));
    final RenderParagraph para = tester.renderObject<RenderParagraph>(
      find.byWidget(rich),
    );
    final String plain = rich.text.toPlainText();
    final int start = plain.indexOf('Inflect');
    final List<TextBox> boxes = para.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + 7),
    );
    final Offset origin = para.localToGlobal(Offset.zero);
    final double lineTop = origin.dy + boxes.first.top;
    final double lineBottom = origin.dy + boxes.first.bottom;
    final double lineCentre = (lineTop + lineBottom) / 2;
    final double fontSize =
        (rich.text as TextSpan).style?.fontSize ??
        Theme.of(tester.element(find.byWidget(rich)))
            .textTheme
            .bodyMedium!
            .fontSize!;
    // Height: the icon is the font size (the glyph height of a line).
    expect(icon.height, closeTo(fontSize, 4));
    expect(icon.height, lessThanOrEqualTo(lineBottom - lineTop + 0.5));
    // Centre: within 1 px of the text line centre.
    expect((icon.center.dy - lineCentre).abs(), lessThan(1.0));
  });

  testWidgets('hover opens the card after the delay and closes on exit', (
    tester,
  ) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext c) {
            ctx = c;
            return const SizedBox(height: 40);
          },
        ),
      ),
    );
    LinkPreviewHover.enter(
      ctx,
      'https://h.com/a',
      const PointerEnterEvent(
        kind: PointerDeviceKind.mouse,
        position: Offset(100, 400),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(LinkPreviewHover.isShowing, isFalse);
    await tester.pump(LinkPreviewHover.showDelay);
    await tester.pumpAndSettle();
    expect(LinkPreviewHover.isShowing, isTrue);
    expect(find.text('Card title · Hugging Face'), findsOneWidget);
    // Above the link when there is room.
    expect(tester.getRect(find.byType(LinkPreviewCard)).bottom, lessThan(400));
    expect(tester.getSize(find.byType(LinkPreviewCard)).width, 300);

    LinkPreviewHover.exit();
    await tester.pump(
      LinkPreviewHover.hideDelay + const Duration(milliseconds: 20),
    );
    await tester.pumpAndSettle();
    expect(LinkPreviewHover.isShowing, isFalse);
  });

  testWidgets('touch: long press shows the card, short tap opens', (
    tester,
  ) async {
    int opened = 0;
    late BuildContext ctx;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext c) {
            ctx = c;
            return const SizedBox(height: 40);
          },
        ),
      ),
    );
    final TapGestureRecognizer r = linkPreviewRecognizer(
      ctx,
      'https://h.com/a',
      () => opened++,
    );
    addTearDown(r.dispose);

    // Short tap.
    r.onTapDown!(
      TapDownDetails(
        globalPosition: const Offset(100, 300),
        kind: PointerDeviceKind.touch,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    r.onTap!();
    expect(opened, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(LinkPreviewHover.isShowing, isFalse);

    // Long press.
    r.onTapDown!(
      TapDownDetails(
        globalPosition: const Offset(100, 300),
        kind: PointerDeviceKind.touch,
      ),
    );
    await tester.pump(LinkPreviewHover.longPressDelay);
    await tester.pumpAndSettle();
    expect(LinkPreviewHover.isShowing, isTrue);
    r.onTap!(); // finger lifts: must not open the link
    expect(opened, 1);
  });

  testWidgets('touch never opens the hover card', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (BuildContext c) {
            ctx = c;
            return const SizedBox(height: 40);
          },
        ),
      ),
    );
    LinkPreviewHover.enter(
      ctx,
      'https://h.com/a',
      const PointerEnterEvent(kind: PointerDeviceKind.touch),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(LinkPreviewHover.isShowing, isFalse);
  });
}
