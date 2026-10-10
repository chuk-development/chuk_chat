// Each registered component must have the upstream positional
// signature, character for character. The source of truth is the
// generated library spec in test/openui/fixtures/upstream/
// (thesysdev/openui, MIT, Copyright (c) 2011-2024 Thesys Inc.).
// The chat library is used, plus Stack and Modal from the general one.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui.dart';

Map<String, String> _signatures(String file) {
  final list = jsonDecode(
    File('test/openui/fixtures/upstream/$file').readAsStringSync(),
  ) as List<Object?>;
  return <String, String>{
    for (final c in list.cast<Map<String, Object?>>())
      c['name']! as String: c['signature']! as String,
  };
}

/// The 86 upstream components chuk_chat ports, with their signatures.
Map<String, String> upstreamSignatures() {
  final general = _signatures('components-general.json');
  return <String, String>{
    ..._signatures('components-chat.json'),
    'Stack': general['Stack']!,
    'Modal': general['Modal']!,
  };
}

void main() {
  final upstream = upstreamSignatures();

  test('the upstream set has 86 components', () {
    expect(upstream, hasLength(86));
  });

  for (final def in chukOpenUiLibrary.components) {
    test('${def.name} matches the upstream signature', () {
      expect(upstream.keys, contains(def.name));
      expect(def.signature, upstream[def.name]);
    });
  }

  test('report: components not registered yet', () {
    final missing =
        upstream.keys.where((n) => !chukOpenUiLibrary.contains(n)).toList()
          ..sort();
    print('OpenUI components missing (${missing.length}): $missing');
  });

  test('all 86 upstream components are registered', () {
    expect(upstream.keys.where((n) => !chukOpenUiLibrary.contains(n)), isEmpty);
  });
}
