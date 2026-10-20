import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tool_prompt_builder.dart';
import 'package:chuk_chat/utils/answer_blocks_parser.dart';
import 'package:chuk_chat/utils/token_estimator.dart';

AnswerBlockSegment _onlyBlock(List<AnswerSegment> segs) =>
    segs.whereType<AnswerBlockSegment>().single;

void main() {
  group('splitAnswerBlocks', () {
    test('text without blocks comes back unchanged', () {
      const String text = 'Hello **world**\n\n- a\n- b';
      final List<AnswerSegment> segs = splitAnswerBlocks(text);
      expect(segs, hasLength(1));
      expect((segs.single as AnswerTextSegment).text, text);
    });

    test('a closed block splits the text around it', () {
      final List<AnswerSegment> segs = splitAnswerBlocks(
        'Intro\n::: steps Setup\n1. One\n2. Two\n:::\nOutro',
      );
      expect(segs, hasLength(3));
      expect((segs[0] as AnswerTextSegment).text.trim(), 'Intro');
      final AnswerBlockSegment b = segs[1] as AnswerBlockSegment;
      expect(b.kind, AnswerBlockKind.steps);
      expect(b.arg, 'Setup');
      expect(b.lines, <String>['1. One', '2. Two']);
      expect(b.closed, isTrue);
      expect((segs[2] as AnswerTextSegment).text.trim(), 'Outro');
    });

    test('an unclosed block renders with the lines that are there', () {
      final AnswerBlockSegment b = _onlyBlock(
        splitAnswerBlocks('::: timeline\n2019: First\n2021: Sec'),
      );
      expect(b.kind, AnswerBlockKind.timeline);
      expect(b.closed, isFalse);
      expect(b.lines, <String>['2019: First', '2021: Sec']);
    });

    test('a half-typed closing marker is not shown as a line', () {
      final AnswerBlockSegment b = _onlyBlock(
        splitAnswerBlocks('::: steps\n1. One\n::'),
      );
      expect(b.lines, <String>['1. One']);
    });

    test('an opening line still being typed shows nothing', () {
      final List<AnswerSegment> segs = splitAnswerBlocks('Intro\n::: ste');
      expect(segs.whereType<AnswerBlockSegment>(), isEmpty);
      final String text = segs.whereType<AnswerTextSegment>().single.text;
      expect(text, isNot(contains(':::')));
      expect(text.trim(), 'Intro');
    });

    test('the next block closes the open one', () {
      final List<AnswerSegment> segs = splitAnswerBlocks(
        '::: steps\n1. A\n::: timeline\n2020: B\n:::',
      );
      final List<AnswerBlockSegment> blocks = segs
          .whereType<AnswerBlockSegment>()
          .toList();
      expect(blocks.map((b) => b.kind), <AnswerBlockKind>[
        AnswerBlockKind.steps,
        AnswerBlockKind.timeline,
      ]);
      expect(blocks.first.lines, <String>['1. A']);
    });

    test('an unknown directive falls back to plain Markdown', () {
      final List<AnswerSegment> segs = splitAnswerBlocks(
        'Before\n::: fancy Title\nSome **text**\n:::\nAfter',
      );
      expect(segs.whereType<AnswerBlockSegment>(), isEmpty);
      final String text = segs
          .whereType<AnswerTextSegment>()
          .map((s) => s.text)
          .join();
      expect(text, isNot(contains(':::')));
      expect(text, contains('Title'));
      expect(text, contains('Some **text**'));
      expect(text, contains('After'));
    });

    test('a ::: line inside a fenced code block is code', () {
      const String text = '```\n::: steps\n1. x\n:::\n```';
      final List<AnswerSegment> segs = splitAnswerBlocks(text);
      expect(segs.whereType<AnswerBlockSegment>(), isEmpty);
    });

    test('a fence inside a block does not close it early', () {
      final AnswerBlockSegment b = _onlyBlock(
        splitAnswerBlocks('::: steps\n1. A\n```\n:::\n```\n2. B\n:::'),
      );
      expect(b.lines, hasLength(5));
      expect(b.closed, isTrue);
    });

    test('GitHub alerts become alert blocks', () {
      final AnswerBlockSegment b = _onlyBlock(
        splitAnswerBlocks('Text\n\n> [!WARNING]\n> Do not **format**.\nNext'),
      );
      expect(b.kind, AnswerBlockKind.alert);
      expect(b.arg, 'WARNING');
      expect(b.lines, <String>['Do not **format**.']);
    });

    test('a plain block quote stays Markdown', () {
      final List<AnswerSegment> segs = splitAnswerBlocks('> just a quote');
      expect(segs.single, isA<AnswerTextSegment>());
    });
  });

  group('parseSteps', () {
    test('titles, text, commands and warnings, with nested Markdown', () {
      final StepsSpec spec = parseSteps('Unlock', <String>[
        '1. Find the **partition**',
        r'$ lsblk -f',
        r'$ sudo blkid',
        'Look for `crypto_LUKS`:',
        '- nvme0n1p3',
        '- sda2',
        '! Disk password, not the login',
        '2. Open it',
      ]);
      expect(spec.title, 'Unlock');
      expect(spec.steps, hasLength(2));
      final StepItem first = spec.steps.first;
      expect(first.label, '1');
      expect(first.title, 'Find the **partition**');
      expect(first.parts.map((p) => p.kind), <StepPartKind>[
        StepPartKind.command,
        StepPartKind.text,
        StepPartKind.warning,
      ]);
      expect(first.parts[0].text, 'lsblk -f\nsudo blkid');
      // Consecutive text lines stay one Markdown chunk, so the list is a list.
      expect(
        first.parts[1].text,
        'Look for `crypto_LUKS`:\n- nvme0n1p3\n- sda2',
      );
      expect(first.parts[2].text, 'Disk password, not the login');
    });

    test('abc letters the steps and leaves the title', () {
      final StepsSpec spec = parseSteps('abc Pancakes', <String>[
        'a. Mix flour and milk',
        'b. Rest ten minutes',
        'c. Fry',
      ]);
      expect(spec.title, 'Pancakes');
      expect(spec.steps.map((s) => s.label), <String>['A', 'B', 'C']);
      expect(spec.steps.last.title, 'Fry');
    });

    test('body before the first title opens an untitled step', () {
      final StepsSpec spec = parseSteps('', <String>['Just text']);
      expect(spec.steps.single.title, '');
      expect(spec.steps.single.label, '1');
    });
  });

  group('parseTimeline', () {
    test('splits at the first colon-space and reads the star', () {
      final List<TimelineEntry> e = parseTimeline(<String>[
        '2019: Buys shares',
        '*2021-01: Short squeeze',
        '12:30: Lunch',
        'No date here',
      ]);
      expect(e[0].label, '2019');
      expect(e[1].highlight, isTrue);
      expect(e[1].label, '2021-01');
      expect(e[2].label, '12:30');
      expect(e[2].text, 'Lunch');
      expect(e[3].label, '');
      expect(e[3].text, 'No date here');
    });
  });

  group('parseTimeline bold labels', () {
    test('a bold label ends at its marker, not at a later colon', () {
      final List<TimelineEntry> e = parseTimeline(<String>[
        '- **Goethe:** Faust I & II (Riesengeschichte: Wette), Der Erlkönig',
        '- **Schiller**: Die Räuber',
        '- **1808**: Faust I',
      ]);
      expect(e[0].label, 'Goethe');
      expect(e[0].text, startsWith('Faust I & II'));
      expect(e[1].label, 'Schiller');
      expect(e[1].text, 'Die Räuber');
      expect(e[2].label, '1808');
    });

    test('names are not dates, years are', () {
      expect(
        timelineIsDated(
          parseTimeline(<String>[
            '- **Goethe:** Faust',
            '- **Schiller:** Tell',
          ]),
        ),
        isFalse,
      );
      expect(
        timelineIsDated(parseTimeline(<String>['2019: A', '2021-01: B'])),
        isTrue,
      );
    });

    test('stripLabelEmphasis', () {
      expect(stripLabelEmphasis('**Goethe:**'), 'Goethe');
      expect(stripLabelEmphasis('__x__'), 'x');
      expect(stripLabelEmphasis('2021'), '2021');
    });
  });

  group('parseScale', () {
    test('range, unit, ticks and marker', () {
      final ScaleSpec spec = parseScale('1800–6500 K', <String>[
        '2000: Candle',
        '2.700: Warm white',
        '@ 2700: your lamp',
      ])!;
      expect(spec.min, 1800);
      expect(spec.max, 6500);
      expect(spec.unit, 'K');
      expect(spec.isKelvin, isTrue);
      expect(spec.ticks.map((t) => t.value), <double>[2000, 2700]);
      expect(spec.markers.single.label, 'your lamp');
      expect(spec.fraction(1800), 0);
      expect(spec.fraction(9000), 1);
    });

    test('no range: the values give it', () {
      final ScaleSpec spec = parseScale('pH', <String>['0: acid', '14: base'])!;
      expect(spec.min, 0);
      expect(spec.max, 14);
    });

    test('nothing drawable returns null', () {
      expect(parseScale('', <String>['one: thing']), isNull);
      expect(parseScale('', <String>['5: only one']), isNull);
    });

    test('loose numbers', () {
      expect(parseLooseNumber('2.700'), 2700);
      expect(parseLooseNumber('2,700'), 2700);
      expect(parseLooseNumber('2,5'), 2.5);
      expect(parseLooseNumber('7.4'), 7.4);
      expect(parseLooseNumber('1.234,5'), 1234.5);
      expect(parseLooseNumber('-3'), -3);
      expect(parseLooseNumber('none'), isNull);
    });
  });

  group('visual blocks', () {
    test('bars: rows, note and tag', () {
      final AnswerBlockSegment seg = _onlyBlock(
        splitAnswerBlocks(
          '::: bars BF16 · nur Modellgewichte\ntag: Rechenbasis\n'
          'Step 5 | ~1.200 GB | 600B Gesamtparameter\n'
          'GLM Flash | ~640 GB | 320B Gesamtparameter\n'
          '! Parameter × 2 Byte\n:::',
        ),
      );
      expect(seg.kind, AnswerBlockKind.bars);
      final BarsSpec spec = parseBars(seg.arg, seg.lines);
      expect(spec.title, 'BF16 · nur Modellgewichte');
      expect(spec.tag, 'Rechenbasis');
      expect(spec.rows, hasLength(2));
      expect(spec.rows[0].label, 'Step 5');
      expect(spec.rows[0].valueText, '~1.200 GB');
      expect(spec.rows[0].value, 1200);
      expect(spec.rows[0].sub, '600B Gesamtparameter');
      expect(spec.rows[1].value, 640);
      expect(spec.note, 'Parameter × 2 Byte');
    });

    test('kpi: value, label, icon, tag', () {
      final AnswerBlockSegment seg = _onlyBlock(
        splitAnswerBlocks(
          '::: kpi\n82 % | Luftfeuchtigkeit | droplet\n7 km/h | Wind | wind\n:::',
        ),
      );
      final KpiSpec spec = parseKpi(seg.arg, seg.lines);
      expect(spec.tiles, hasLength(2));
      expect(spec.tiles[0].value, '82 %');
      expect(spec.tiles[0].label, 'Luftfeuchtigkeit');
      expect(spec.tiles[0].icon, 'droplet');
      expect(spec.tiles[1].icon, 'wind');
      expect(spec.title, isEmpty);
    });

    test('kpi parser: tag line is read, not a tile', () {
      final KpiSpec spec = parseKpi('', <String>['tag: Heute', '15 °C | Kiel']);
      expect(spec.tag, 'Heute');
      expect(spec.tiles, hasLength(1));
    });

    test('tiles: label, icon, sub', () {
      final TilesSpec spec = parseTiles('Bot', <String>[
        'Chatbot | chat',
        'Such-Crawler | search | durchsucht Seiten',
      ]);
      expect(spec.title, 'Bot');
      expect(spec.tiles[0].label, 'Chatbot');
      expect(spec.tiles[0].icon, 'chat');
      expect(spec.tiles[0].sub, isEmpty);
      expect(spec.tiles[1].sub, 'durchsucht Seiten');
    });

    test('cards: records with keys, chips split, blank line separates', () {
      final CardsSpec spec = parseCards('Hotels', <String>[
        'Alpenruhe Panorama',
        'image: https://example.com/a.jpg',
        'badge: Für deinen Bergmoment',
        'subtitle: Grindelwald, Schweiz',
        'meta: 4,8 · 128 Bewertungen',
        'meta: Panoramabalkon inklusive',
        'chips: Panoramabalkon, Berg-Spa',
        'price: 248 CHF / Nacht',
        'url: https://example.com/a',
        'action: Details',
        '',
        'Auralis Quiet One',
        'price: 249 €',
      ]);
      expect(spec.label, 'Hotels');
      expect(spec.cards, hasLength(2));
      expect(spec.cards[0].title, 'Alpenruhe Panorama');
      expect(spec.cards[0].image, 'https://example.com/a.jpg');
      expect(spec.cards[0].badge, 'Für deinen Bergmoment');
      expect(spec.cards[0].subtitle, 'Grindelwald, Schweiz');
      expect(spec.cards[0].metas, hasLength(2));
      expect(spec.cards[0].chips, <String>['Panoramabalkon', 'Berg-Spa']);
      expect(spec.cards[0].price, '248 CHF / Nacht');
      expect(spec.cards[0].url, 'https://example.com/a');
      expect(spec.cards[0].action, 'Details');
      expect(spec.cards[1].title, 'Auralis Quiet One');
      expect(spec.cards[1].price, '249 €');
    });

    test('cards: a line before any key is the title', () {
      final CardsSpec spec = parseCards('', <String>[
        'Title line',
        'Some fact without a key',
      ]);
      expect(spec.cards, hasLength(1));
      expect(spec.cards[0].title, 'Title line');
      expect(spec.cards[0].metas, <String>['Some fact without a key']);
    });

    test('cards: a known key with an empty value is dropped', () {
      final CardsSpec spec = parseCards('', <String>[
        'Some stay',
        'image:',
        'url: ',
        'chips:',
      ]);
      expect(spec.cards, hasLength(1));
      expect(spec.cards[0].title, 'Some stay');
      expect(spec.cards[0].image, isEmpty);
      expect(spec.cards[0].url, isEmpty);
      expect(spec.cards[0].chips, isEmpty);
      expect(spec.cards[0].metas, isEmpty);
    });

    test('ask: question and chips', () {
      final AskSpec spec = parseAsk('Welche Basis?', <String>[
        'Aktive Parameter',
        '- BF16 & FP8',
      ]);
      expect(spec.question, 'Welche Basis?');
      expect(spec.chips, <String>['Aktive Parameter', 'BF16 & FP8']);
    });

    test('source: rows with and without url', () {
      final SourceSpec spec = parseSource('', <String>[
        'Artikel | https://example.org/a',
        'Nur Titel',
      ]);
      expect(spec.rows, hasLength(2));
      expect(spec.rows[0].title, 'Artikel');
      expect(spec.rows[0].url, 'https://example.org/a');
      expect(spec.rows[1].url, isEmpty);
    });

    test('source: url-only row falls back to the argument as title', () {
      final SourceSpec spec = parseSource('Quelle', <String>[
        '| https://example.org/a',
      ]);
      expect(spec.rows, hasLength(1));
      expect(spec.rows[0].title, 'Quelle');
      expect(spec.rows[0].url, 'https://example.org/a');
    });

    test('prompt documents the visual blocks', () {
      final String prompt = ToolPromptBuilder(discoveryMode: false)
          .buildToolProtocolSection(tools: const <Map<String, dynamic>>[]);
      expect(prompt, contains('::: bars'));
      expect(prompt, contains('::: kpi'));
      expect(prompt, contains('::: tiles'));
      expect(prompt, contains('::: cards'));
      expect(prompt, contains('::: ask'));
      expect(prompt, contains('::: source'));
      expect(prompt, contains('::: status'));
      expect(prompt, contains('never bullets'));
      expect(prompt, contains('Never invent a URL'));
    });
  });

  group('parseStatus', () {
    test('header, positional fields, chip label, action, footer', () {
      final AnswerBlockSegment seg = _onlyBlock(
        splitAnswerBlocks(
          '::: status 4 offene Zahlungen · 122,20 € + 50 \$\n'
          'Hetzner | Karte fehlgeschlagen | 102,20 € | failed | 16.10. | hetzner.com | Bezahlen https://hetzner.com/pay\n'
          'Mobbin | Abo endet | | due Letzte Chance | 18.10. | https://www.mobbin.com/x\n'
          'more: Ältere Erinnerungen (Tailscale, Lebara …)\n'
          'Tailscale | Erinnerung | | ok | 02.09.\n'
          ':::',
        ),
      );
      expect(seg.kind, AnswerBlockKind.status);
      final StatusSpec spec = parseStatus(seg.arg, seg.lines);
      expect(spec.title, '4 offene Zahlungen');
      expect(spec.summary, '122,20 € + 50 \$');
      expect(spec.items, hasLength(2));
      final StatusItem h = spec.items[0];
      expect(h.title, 'Hetzner');
      expect(h.detail, 'Karte fehlgeschlagen');
      expect(h.amount, '102,20 €');
      expect(h.kind, StatusKind.failed);
      expect(h.statusLabel, 'Failed');
      expect(h.date, '16.10.');
      expect(h.domain, 'hetzner.com');
      expect(h.actionLabel, 'Bezahlen');
      expect(h.actionUrl, 'https://hetzner.com/pay');
      final StatusItem m = spec.items[1];
      expect(m.amount, '');
      expect(m.kind, StatusKind.due);
      expect(m.statusLabel, 'Letzte Chance');
      expect(m.domain, 'mobbin.com');
      expect(m.actionUrl, '');
      expect(spec.moreLabel, startsWith('Ältere Erinnerungen'));
      expect(spec.moreItems.single.kind, StatusKind.ok);
    });

    test('status words, aliases and unknown labels', () {
      StatusItem one(String status) =>
          parseStatus('', <String>['X | | | $status']).items.single;
      expect(one('overdue').kind, StatusKind.overdue);
      expect(one('Überfällig').kind, StatusKind.overdue);
      expect(one('Überfällig').statusLabel, 'Überfällig');
      expect(one('status:paid').kind, StatusKind.ok);
      expect(one('due: Morgen fällig').statusLabel, 'Morgen fällig');
      expect(one('In Zustellung').kind, StatusKind.neutral);
      expect(one('In Zustellung').statusLabel, 'In Zustellung');
      expect(one('').statusLabel, '');
    });

    test('domain is a plain public host or nothing', () {
      expect(statusDomain('Hetzner.com'), 'hetzner.com');
      expect(statusDomain('https://www.x.org/a'), 'x.org');
      expect(statusDomain('192.168.1.1'), '');
      expect(statusDomain('localhost'), '');
      expect(statusDomain('printer.local'), '');
      expect(statusDomain('not a host'), '');
    });

    test('a row needs a title; a non-http action is dropped', () {
      final StatusSpec spec = parseStatus('', <String>[
        ' | nur Detail',
        '- **Lebara** | Rechnung | 10 € | ok | | | Öffnen javascript:alert(1)',
      ]);
      expect(spec.items.single.title, 'Lebara');
      expect(spec.items.single.actionUrl, '');
      expect(spec.moreLabel, '');
    });
  });

  group('answer format prompt', () {
    final String prompt = ToolPromptBuilder(discoveryMode: false)
        .buildToolProtocolSection(tools: const <Map<String, dynamic>>[]);

    test('is always in the prompt, with the bold-first rule', () {
      expect(prompt, contains('## ANSWER FORMAT'));
      expect(prompt, contains('**bold**'));
      expect(prompt, contains('::: steps'));
      expect(prompt, contains('Never invent a date'));
      expect(prompt, contains('experimental'));
    });

    test('stays small', () {
      final int start = prompt.indexOf('## ANSWER FORMAT');
      final int end = prompt.indexOf('Never invent a URL', start);
      final String section = prompt.substring(
        start,
        end + 'Never invent a URL'.length,
      );
      expect(TokenEstimator.estimateTokens(section), lessThan(650));
    });
  });
}
