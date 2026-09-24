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
      final int end = prompt.indexOf('experimental', start);
      final String section = prompt.substring(start, end);
      expect(TokenEstimator.estimateTokens(section), lessThan(300));
    });
  });
}
