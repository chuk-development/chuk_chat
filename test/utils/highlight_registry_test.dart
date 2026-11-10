// Every syntax-highlight language in lib/utils/highlight_registry.dart
// builds, and registering it pulls in only languages the registry knows.

import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight_core.dart';

import 'package:chuk_chat/utils/highlight_registry.dart';

void main() {
  test('every language factory builds a mode', () {
    expect(languageFactories, isNotEmpty);
    for (final entry in languageFactories.entries) {
      expect(
        entry.value,
        returnsNormally,
        reason: 'language ${entry.key} throws while building',
      );
    }
    expect(allLanguages.keys.toSet(), languageFactories.keys.toSet());
  });

  test('isKnownLanguage matches the factory table', () {
    for (final name in languageFactories.keys) {
      expect(isKnownLanguage(name), isTrue, reason: name);
    }
    expect(isKnownLanguage('no-such-language'), isFalse);
  });

  test('every language registers and highlights a line', () {
    for (final name in languageFactories.keys) {
      final highlighter = Highlight();
      registerLanguageWithEmbeds(highlighter, name);
      expect(
        () => highlighter.parse('x = 1', language: name),
        returnsNormally,
        reason: 'language $name fails on a trivial line',
      );
    }
  });
}
