// Key parity between the UI string tables in lib/l10n/.
//
// English is the fallback: `AppLocalizations` looks a key up in the active
// locale and falls back to `stringsEn`. So:
//
// * German is a complete translation: it must carry exactly the English
//   keys. A key missing in German shows English text in a German UI.
// * Spanish, French and Portuguese are partial: a missing key falls back to
//   English, which is accepted. A key that English does not have is dead
//   (a renamed or deleted string) and fails.
// * A translated value must use the same `{placeholder}` names as English,
//   or the substitution in `AppLocalizations` leaves `{name}` in the UI.
// * Every literal key `AppLocalizations` reads with `_get('key')` exists in
//   English, or the UI shows the raw key.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/strings_de.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/l10n/strings_es.dart';
import 'package:chuk_chat/l10n/strings_fr.dart';
import 'package:chuk_chat/l10n/strings_pt.dart';

final RegExp _placeholder = RegExp(r'\{([A-Za-z0-9_]+)\}');

Set<String> _placeholders(String value) =>
    _placeholder.allMatches(value).map((m) => m.group(1)!).toSet();

/// Keys of [locale] whose placeholders differ from English.
List<String> _placeholderMismatches(Map<String, String> locale) {
  final out = <String>[];
  for (final entry in locale.entries) {
    final en = stringsEn[entry.key];
    if (en == null) continue;
    final want = _placeholders(en);
    final got = _placeholders(entry.value);
    if (want.length != got.length || !want.containsAll(got)) {
      out.add('${entry.key}: en $want, got $got');
    }
  }
  return out;
}

void main() {
  test('every key AppLocalizations reads exists in English', () {
    final source = File('lib/l10n/app_localizations.dart').readAsStringSync();
    final used = RegExp(r"_get\('([A-Za-z0-9_]+)'\)")
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toSet();
    expect(used, isNotEmpty);
    final missing = used.difference(stringsEn.keys.toSet()).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason: 'Add these keys to lib/l10n/strings_en.dart: $missing',
    );
  });

  test('German has exactly the English keys', () {
    final en = stringsEn.keys.toSet();
    final de = stringsDe.keys.toSet();
    final missing = en.difference(de).toList()..sort();
    final extra = de.difference(en).toList()..sort();
    expect(
      missing,
      isEmpty,
      reason: 'Add these keys to lib/l10n/strings_de.dart: $missing',
    );
    expect(
      extra,
      isEmpty,
      reason:
          'These German keys have no English source. Add them to '
          'strings_en.dart or delete them: $extra',
    );
  });

  final partial = <String, Map<String, String>>{
    'es': stringsEs,
    'fr': stringsFr,
    'pt': stringsPt,
  };

  for (final entry in partial.entries) {
    test('${entry.key} has no key that English does not have', () {
      final extra =
          entry.value.keys.toSet().difference(stringsEn.keys.toSet()).toList()
            ..sort();
      expect(
        extra,
        isEmpty,
        reason:
            'Dead keys in lib/l10n/strings_${entry.key}.dart (renamed or '
            'removed in English): $extra',
      );
    });
  }

  final all = <String, Map<String, String>>{'de': stringsDe, ...partial};
  for (final entry in all.entries) {
    test('${entry.key} uses the English placeholders', () {
      expect(
        _placeholderMismatches(entry.value),
        isEmpty,
        reason:
            'A translation must use the same {placeholder} names as '
            'English (lib/l10n/strings_${entry.key}.dart).',
      );
    });
  }
}
