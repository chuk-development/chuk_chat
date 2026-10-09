// The app side of docs/WIRE_CONTRACT.md, "Fragments" (bead chuk_chat-zhhd).
// The host splits a payload that is too large for one relay frame; the app
// joins the parts and dispatches the payload once.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_frame_fragments.dart';

/// The host's split (`fragment_plaintexts` in chuk_agents_executor.protocol).
List<Map<String, dynamic>> split(
  Map<String, dynamic> payload, {
  int chunk = 256 * 1024,
  String id = 'abc123',
}) {
  final whole = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  final count = (whole.length + chunk - 1) ~/ chunk;
  return <Map<String, dynamic>>[
    for (var i = 0; i < count; i++)
      <String, dynamic>{
        'type': 'fragment',
        'fragment_id': id,
        'index': i,
        'count': count,
        'total_bytes': whole.length,
        'data': base64.encode(
          whole.sublist(
            i * chunk,
            (i + 1) * chunk < whole.length ? (i + 1) * chunk : whole.length,
          ),
        ),
      },
  ];
}

void main() {
  final big = <String, dynamic>{
    'type': 'file',
    'name': 'pi.zip',
    'mime_type': 'application/zip',
    'data': base64.encode(List<int>.generate(900000, (i) => i & 0xff)),
  };

  test('a payload that is not a fragment passes through unchanged', () {
    final assembler = AgentsFragmentAssembler();
    final payload = <String, dynamic>{'type': 'delta', 'text': 'hi'};

    expect(identical(assembler.add(payload), payload), isTrue);
  });

  test('the parts join back into the payload, once, at the last part', () {
    final assembler = AgentsFragmentAssembler();
    final parts = split(big);
    expect(parts.length, greaterThan(1));

    final results = parts.map(assembler.add).toList();

    expect(results.sublist(0, results.length - 1), everyElement(isNull));
    expect(results.last, big);
    expect(assembler.pendingCount, 0);
  });

  test('the parts join in any order', () {
    final assembler = AgentsFragmentAssembler();
    final results = split(big).reversed.map(assembler.add).toList();

    expect(results.last, big);
  });

  test('bad parts are dropped, never thrown', () {
    final assembler = AgentsFragmentAssembler();
    final good = split(big).first;

    expect(assembler.add({...good, 'data': '%%% not base64'}), isNull);
    expect(assembler.add({...good, 'index': 999}), isNull);
    expect(assembler.add({...good, 'count': 0}), isNull);
    expect(assembler.add({...good, 'total_bytes': 1 << 40}), isNull);
    expect(assembler.add(<String, dynamic>{'type': 'fragment'}), isNull);
  });

  test('a part that contradicts its payload drops that payload', () {
    final assembler = AgentsFragmentAssembler();
    final parts = split(big);

    assembler.add(parts[0]);
    expect(assembler.add({...parts[1], 'count': parts.length + 1}), isNull);
    expect(assembler.pendingCount, 0);
  });

  test('the oldest incomplete payload is evicted first', () {
    final assembler = AgentsFragmentAssembler(maxPending: 2);
    final a = split(<String, dynamic>{'type': 'a', 'd': 'a' * 100}, chunk: 40, id: 'a');
    final b = split(<String, dynamic>{'type': 'b', 'd': 'b' * 100}, chunk: 40, id: 'b');
    final c = split(<String, dynamic>{'type': 'c', 'd': 'c' * 100}, chunk: 40, id: 'c');

    assembler.add(a[0]);
    assembler.add(b[0]);
    assembler.add(c[0]); // evicts "a"

    expect(a.skip(1).map(assembler.add).toList().last, isNull);
    expect(c.skip(1).map(assembler.add).toList().last, <String, dynamic>{
      'type': 'c',
      'd': 'c' * 100,
    });
  });

  test('clear drops every incomplete payload', () {
    final assembler = AgentsFragmentAssembler();
    final parts = split(big);
    assembler.add(parts[0]);

    assembler.clear();

    expect(assembler.pendingCount, 0);
    expect(parts.skip(1).map(assembler.add).toList().last, isNull);
  });
}
