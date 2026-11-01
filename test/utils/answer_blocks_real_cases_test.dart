// Cases from real answers that drew wrong (audit of 2026-11-01). The texts
// are shortened; the shape of the model's mistake is kept.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/answer_blocks_parser.dart';

AnswerBlockSegment _block(String text) =>
    splitAnswerBlocks(text).whereType<AnswerBlockSegment>().single;

void main() {
  test('a `::` close ends the block, the text after it stays text', () {
    final List<AnswerSegment> out = splitAnswerBlocks(
      '::: cards Options\n**COSMIC** (System76)\nA desktop.\n::\n\nAfter it.',
    );
    expect(out.first, isA<AnswerBlockSegment>());
    final String tail = (out.last as AnswerTextSegment).text;
    expect(tail, contains('After it.'));
  });

  test('card title loses its bold markers, the prose becomes the body', () {
    final AnswerBlockSegment b = _block(
      '::: cards\n**COSMIC** (System76)\nRust desktop with touch.\n:::\n',
    );
    final AnswerCard card = parseCards(b.arg, b.lines).cards.single;
    expect(card.title, 'COSMIC (System76)');
    expect(card.body, 'Rust desktop with touch.');
  });

  test('cards split without `--` at the next short plain line', () {
    final AnswerBlockSegment b = _block(
      '::: cards\n'
      'Kirby CMS\nFlat-file, PHP\nmeta: 99 EUR once\nchips: Panel, Files\n'
      'Typemill\nFlat-file, free\nmeta: Open source\n:::\n',
    );
    final List<AnswerCard> cards = parseCards(b.arg, b.lines).cards;
    expect(cards.map((AnswerCard c) => c.title), <String>[
      'Kirby CMS',
      'Typemill',
    ]);
  });

  test('a last short line after keys is the body, not a new card', () {
    final AnswerBlockSegment b = _block(
      '::: cards\nItem\nprice: 10 €\nCompact and easy to carry\n:::\n',
    );
    final List<AnswerCard> cards = parseCards(b.arg, b.lines).cards;
    expect(cards, hasLength(1));
    expect(cards.single.body, 'Compact and easy to carry');
  });

  test('thumb is read as the fallback image', () {
    final AnswerBlockSegment b = _block(
      '::: cards\nGo2\nimage: https://a.de/1.webp\nthumb: https://b.de/1.jpg\n:::\n',
    );
    expect(parseCards(b.arg, b.lines).cards.single.thumb, 'https://b.de/1.jpg');
  });

  test('a tile subline on its own line stays with its tile', () {
    final AnswerBlockSegment b = _block(
      '::: tiles\nVulniPulse | shield\nPush app for CVEs\n'
      'Vulmon | search\nFree feed\n:::\n',
    );
    final TilesSpec spec = parseTiles(b.arg, b.lines);
    expect(spec.tiles, hasLength(2));
    expect(spec.tiles[0].sub, 'Push app for CVEs');
  });

  test('an explicit bullet stays its own tile', () {
    final AnswerBlockSegment b = _block('::: tiles\n- First | star\n- Second\n:::\n');
    expect(parseTiles(b.arg, b.lines).tiles, hasLength(2));
  });

  test('the ask question on the first line is the heading, not a chip', () {
    final AnswerBlockSegment b = _block(
      '::: ask\nCoolify or Kirby?\nCoolify setup\nKirby CMS\n:::\n',
    );
    final AskSpec spec = parseAsk(b.arg, b.lines);
    expect(spec.question, 'Coolify or Kirby?');
    expect(spec.chips, <String>['Coolify setup', 'Kirby CMS']);
  });

  test('bars with prose values are not comparable', () {
    final AnswerBlockSegment prose = _block(
      '::: bars\nPHP2Shell | 2× RCE, PHP 5.4–8.5, CVSS 3.1 bis 9.8 | web\n'
      'Patch Tuesday | ~1.400–1.460 CVEs, ~72–96 kritisch | Windows\n:::\n',
    );
    expect(parseBars(prose.arg, prose.lines).isComparable, isFalse);
    final AnswerBlockSegment real = _block(
      '::: bars\nStep 5 | ~1.200 GB\nGLM | ~640 GB\n:::\n',
    );
    expect(parseBars(real.arg, real.lines).isComparable, isTrue);
  });

  test('`::: warning` is an alert, `:::Kurz: text` keeps its word', () {
    final AnswerBlockSegment alert = _block('::: warning\nCareful.\n:::\n');
    expect(alert.kind, AnswerBlockKind.alert);
    expect(alert.arg, 'WARNING');
    final AnswerBlockSegment lead = _block(':::Wichtig: Foo\n:::\n');
    expect(lead.lines, <String>['Foo']);
    final List<AnswerSegment> out = splitAnswerBlocks(':::Kurz: Ja.\n\nMehr.\n:::\n');
    expect((out.single as AnswerTextSegment).text, startsWith('Kurz: Ja.'));
  });

  group('extractPageImage', () {
    final Uri page = Uri.parse('https://shop.de/p/1');

    test('reads og:image in both attribute orders and resolves it', () {
      expect(
        extractPageImage('<meta property="og:image" content="/a.jpg?x=1&amp;y=2">', page),
        'https://shop.de/a.jpg?x=1&y=2',
      );
      expect(
        extractPageImage("<meta content='https://c.de/b.png' name='twitter:image'/>", page),
        'https://c.de/b.png',
      );
    });

    test('an http image does not stop the search', () {
      expect(
        extractPageImage(
          '<meta property="og:image" content="http://c.de/a.jpg">'
          '<meta name="twitter:image" content="https://c.de/b.jpg">',
          page,
        ),
        'https://c.de/b.jpg',
      );
    });

    test('reads JSON-LD, refuses http, empty without an image', () {
      expect(
        extractPageImage('{"image":["https:\\/\\/c.de\\/j.jpg"]}', page),
        'https://c.de/j.jpg',
      );
      expect(extractPageImage('<meta property="og:image" content="http://c.de/a">', page), '');
      expect(extractPageImage('<html></html>', page), '');
    });
  });
}
