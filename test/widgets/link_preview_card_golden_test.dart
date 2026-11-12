// What links look like in a message: the site icon in front of each link,
// a bare URL as a short name, and the floating preview card (compact, and
// with an og:image), in light and dark. Real Roboto, so this also measures
// that the icon sits centred on the text line with a real font.
//
// Regenerate with
//
//   flutter test test/widgets/link_preview_card_golden_test.dart \
//     --update-goldens
//
// and then LOOK at the PNGs.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/link_preview_service.dart';
import 'package:chuk_chat/widgets/link_preview_card.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

import 'charts/chart_test_support.dart';

/// A flat colour PNG of [w]x[h] with a light disc, so image slots show
/// something.
Future<Uint8List> _swatch(int w, int h, Color color) async {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  final Canvas canvas = Canvas(rec);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..color = color,
  );
  canvas.drawCircle(
    Offset(w * 0.5, h * 0.5),
    h * 0.3,
    Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.7),
  );
  final ui.Image img = await rec.endRecording().toImage(w, h);
  final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

const String _message =
    'Neue Modelle: [Inflect Mini v3](https://huggingface.co/owensong/Inflect-Mini-v3) '
    'ist ein englisches TTS mit 34M Parametern. Dazu kommt das Paper '
    '[ESDCodec](https://arxiv.org/abs/2611.14043) und der '
    '[Code](https://github.com/owensong/inflect). Mehr unter '
    'https://www.example.com/voice/overview/ und in der '
    '[OSS-Voice-Übersicht](https://docs.google.com/x).';

Map<String, dynamic> _card(String url) {
  final String host = Uri.parse(url).host;
  return switch (host) {
    'huggingface.co' => <String, dynamic>{
      'url': url,
      'host': host,
      'title': 'owensong/Inflect-Mini-v3',
      'site_name': 'Hugging Face',
      'description':
          'Text-to-Speech model. Download, explore files and run it on '
          'Hugging Face.',
      'icon': 'https://icon/hf',
    },
    'arxiv.org' => <String, dynamic>{
      'url': url,
      'host': host,
      'title':
          'ESDCodec: Ultra-Low Bitrate Speech Codec with Enhanced Semantic '
          'Disentanglement',
      'description':
          'Despite recent advances in neural speech codecs, achieving high '
          'fidelity speech reconstruction at low bitrates remains a '
          'challenge.',
      'image': 'https://img/arxiv',
      'icon': 'https://icon/arxiv',
    },
    'github.com' => <String, dynamic>{
      'url': url,
      'host': host,
      'title': 'GitHub - owensong/inflect',
      'icon': 'https://icon/gh',
    },
    'docs.google.com' => <String, dynamic>{
      'url': url,
      'host': host,
      'title': 'OSS-Voice-Übersicht',
      'icon': 'https://icon/google',
    },
    _ => <String, dynamic>{'url': url, 'empty': true},
  };
}

ThemeData _theme(Brightness b) => ThemeData(
  useMaterial3: true,
  fontFamily: 'Roboto',
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF6B8AFD),
    brightness: b,
  ),
);

Widget _sheet(Brightness b) {
  final ThemeData theme = _theme(b);
  final LinkPreview compact = LinkPreview.fromJson(
    _card('https://huggingface.co/owensong/Inflect-Mini-v3'),
  )!;
  final LinkPreview withImage = LinkPreview.fromJson(
    _card('https://arxiv.org/abs/2611.14043'),
  )!;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 420,
              child: MarkdownMessage(
                text: _message,
                textColor: theme.colorScheme.onSurface,
                backgroundColor: theme.colorScheme.surface,
                wrapWithSelectionArea: false,
              ),
            ),
            const SizedBox(width: 24),
            SizedBox(
              width: kLinkPreviewCardWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  LinkPreviewCard(preview: compact, onTap: () {}),
                  const SizedBox(height: 16),
                  LinkPreviewCard(preview: withImage, onTap: () {}),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(loadChartFonts);

  setUp(() {
    LinkPreviewService.debugReset();
    LinkPreviewService.debugSkipPersistentCache = true;
    LinkPreviewService.debugFetchCard = (String url) async => _card(url);
  });
  tearDown(LinkPreviewService.debugReset);

  for (final Brightness b in Brightness.values) {
    testWidgets('links and preview cards ${b.name}', (tester) async {
      tester.view.physicalSize = const Size(800, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Map<String, Uint8List> images = (await tester.runAsync(
        () async => <String, Uint8List>{
          'https://img/arxiv': await _swatch(600, 314, const Color(0xFF8C2F39)),
          'https://icon/hf': await _swatch(32, 32, const Color(0xFFFFB000)),
          'https://icon/arxiv': await _swatch(32, 32, const Color(0xFFB31B1B)),
          'https://icon/gh': await _swatch(32, 32, const Color(0xFF24292F)),
          'https://icon/google': await _swatch(32, 32, const Color(0xFF4285F4)),
        },
      ))!;
      LinkPreviewService.debugFetchImage = (String url) async => images[url];

      await tester.pumpWidget(_sheet(b));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // With the real font: each icon centred on its text line (1 px).
      final RenderParagraph para = tester
          .renderObjectList<RenderParagraph>(find.byType(RichText))
          .firstWhere(
            (RenderParagraph p) => p.text.toPlainText().contains('Inflect'),
          );
      final String plain = para.text.toPlainText();
      final int start = plain.indexOf('Inflect');
      final TextBox line = para
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + 7),
          )
          .first;
      final double lineCentre =
          para.localToGlobal(Offset.zero).dy + (line.top + line.bottom) / 2;
      final Rect icon = tester.getRect(find.byType(LinkFavicon).first);
      expect((icon.center.dy - lineCentre).abs(), lessThan(1.0));
      expect(icon.height, lessThanOrEqualTo(line.bottom - line.top + 0.5));

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/link_preview_${b.name}.png'),
      );
    });
  }
}
