import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_diff_engine.dart';

void main() {
  group('ArtifactDiffEngine.applyEdits', () {
    test('applies a single exact replacement', () {
      const source = 'hello world';
      final result = ArtifactDiffEngine.applyEdits(source, const [
        ArtifactEdit(oldStr: 'world', newStr: 'flutter'),
      ]);

      expect(result, equals('hello flutter'));
    });

    test('applies multiple edits sequentially', () {
      const source = 'A=1\nB=2\nC=3';
      final result = ArtifactDiffEngine.applyEdits(source, const [
        ArtifactEdit(oldStr: 'A=1', newStr: 'A=10'),
        ArtifactEdit(oldStr: 'B=2', newStr: 'B=20'),
      ]);

      expect(result, equals('A=10\nB=20\nC=3'));
    });

    test('throws if old_str is missing', () {
      expect(
        () => ArtifactDiffEngine.applyEdits('abc', const [
          ArtifactEdit(oldStr: 'xyz', newStr: '1'),
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('throws if old_str appears more than once', () {
      expect(
        () => ArtifactDiffEngine.applyEdits('x\nx', const [
          ArtifactEdit(oldStr: 'x', newStr: 'y'),
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('multi-match error names the matching positions and count', () {
      final source = 'alpha beta alpha gamma alpha';
      try {
        ArtifactDiffEngine.applyEdits(source, const [
          ArtifactEdit(oldStr: 'alpha', newStr: 'A'),
        ]);
        fail('expected StateError');
      } on StateError catch (error) {
        final msg = error.message;
        expect(msg, contains('matches 3 places'));
        expect(msg, contains('Match 1'));
        expect(msg, contains('Match 2'));
        expect(msg, contains('Match 3'));
        expect(msg, contains('action="rewrite"'));
      }
    });

    test('zero-match error mentions the missing needle', () {
      try {
        ArtifactDiffEngine.applyEdits('hello world', const [
          ArtifactEdit(oldStr: 'goodbye', newStr: 'x'),
        ]);
        fail('expected StateError');
      } on StateError catch (error) {
        expect(error.message, contains('not found'));
        expect(error.message, contains('goodbye'));
      }
    });

    test('multi-match error caps shown matches at 3 with overflow note', () {
      final source = List<String>.filled(5, 'foo').join('-');
      try {
        ArtifactDiffEngine.applyEdits(source, const [
          ArtifactEdit(oldStr: 'foo', newStr: 'bar'),
        ]);
        fail('expected StateError');
      } on StateError catch (error) {
        expect(error.message, contains('matches 5 places'));
        expect(error.message, contains('Match 3'));
        expect(error.message, isNot(contains('Match 4')));
        expect(error.message, contains('2 more match'));
      }
    });

    test('throws when too many edits are provided', () {
      final edits = List<ArtifactEdit>.generate(
        6,
        (index) => ArtifactEdit(oldStr: 'a$index', newStr: 'b$index'),
      );

      expect(
        () => ArtifactDiffEngine.applyEdits('a0 a1 a2 a3 a4 a5', edits),
        throwsA(isA<StateError>()),
      );
    });
  });
}
