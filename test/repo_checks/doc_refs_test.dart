// Every repository path that CLAUDE.md and the live docs name exists.
// The checker and its scope are in tool/verify_doc_refs.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/verify_doc_refs.dart';

void main() {
  test('docs only reference files that exist', () {
    final broken = findBrokenDocRefs(Directory.current.path);
    expect(
      broken.map((b) => '$b'),
      isEmpty,
      reason:
          'Fix the path in the doc or restore the file. If the reference is '
          'deliberate (a planned file, another repository), add it with a '
          'reason to tool/verify_doc_refs_allow.json. Run '
          '`dart run tool/verify_doc_refs.dart` for the same list.',
    );
  });
}
