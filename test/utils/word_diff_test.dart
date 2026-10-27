import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/word_diff.dart';

String _side(List<WordDiffSegment> s, WordDiffOp skip) => <String>[
  for (final WordDiffSegment x in s)
    if (x.op != skip) x.text,
].join();

void main() {
  group('wordDiff', () {
    test('equal texts give one equal run and no change', () {
      final List<WordDiffSegment> d = wordDiff('Hi Anna', 'Hi Anna');
      expect(d, <WordDiffSegment>[
        const WordDiffSegment(WordDiffOp.equal, 'Hi Anna'),
      ]);
      expect(wordDiffHasChanges(d), isFalse);
    });

    test('empty to empty is empty', () {
      expect(wordDiff('', ''), isEmpty);
    });

    test('one replaced word', () {
      final List<WordDiffSegment> d = wordDiff(
        'See you on Monday at noon.',
        'See you on Tuesday at noon.',
      );
      expect(d, <WordDiffSegment>[
        const WordDiffSegment(WordDiffOp.equal, 'See you on '),
        const WordDiffSegment(WordDiffOp.removed, 'Monday'),
        const WordDiffSegment(WordDiffOp.inserted, 'Tuesday'),
        const WordDiffSegment(WordDiffOp.equal, ' at noon.'),
      ]);
      expect(wordDiffHasChanges(d), isTrue);
    });

    test('inserted words only', () {
      final List<WordDiffSegment> d = wordDiff(
        'Thanks for the call.',
        'Thanks a lot for the call.',
      );
      expect(
        d.where((WordDiffSegment s) => s.op == WordDiffOp.removed),
        isEmpty,
      );
      expect(
        d
            .where((WordDiffSegment s) => s.op == WordDiffOp.inserted)
            .map((WordDiffSegment s) => s.text.trim()),
        <String>['a lot'],
      );
    });

    test('removed words only', () {
      final List<WordDiffSegment> d = wordDiff(
        'Please, if possible, reply today.',
        'Please reply today.',
      );
      expect(
        d.where((WordDiffSegment s) => s.op == WordDiffOp.inserted),
        isEmpty,
      );
      expect(_side(d, WordDiffOp.inserted), 'Please, if possible, reply today.');
      expect(_side(d, WordDiffOp.removed), 'Please reply today.');
    });

    test('a run of replaced words reads as one removed and one inserted run',
        () {
      final List<WordDiffSegment> d = wordDiff('a b c', 'x y z');
      expect(d, <WordDiffSegment>[
        const WordDiffSegment(WordDiffOp.removed, 'a b c'),
        const WordDiffSegment(WordDiffOp.inserted, 'x y z'),
      ]);
    });

    test('both sides rebuild exactly, newlines included', () {
      const String before = 'Hi Tom,\n\nthe report is late.\nBest, Anna';
      const String after = 'Hi Tom,\n\nthe final report is ready now.\nBest,\nAnna';
      final List<WordDiffSegment> d = wordDiff(before, after);
      expect(_side(d, WordDiffOp.removed), after);
      expect(_side(d, WordDiffOp.inserted), before);
    });

    test('a huge input falls back to one replaced run, still exact', () {
      final String before = List<String>.filled(800, 'alpha').join(' ');
      final String after = List<String>.filled(800, 'beta').join(' ');
      final List<WordDiffSegment> d = wordDiff('x $before', 'x $after');
      expect(_side(d, WordDiffOp.removed), 'x $after');
      expect(_side(d, WordDiffOp.inserted), 'x $before');
      expect(d.first, const WordDiffSegment(WordDiffOp.equal, 'x '));
    });

    test('tokens keep whitespace', () {
      expect(wordDiffTokens(' a  b\n'), <String>[' ', 'a', '  ', 'b', '\n']);
    });
  });
}
