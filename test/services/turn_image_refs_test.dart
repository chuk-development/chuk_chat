// A native tool pass sends the turn's images as server cache refs when the
// server still holds them. The server puts them back on the same history
// entry, after its text (`attach_turn_images`), so the provider bytes stay
// the same; only the upload shrinks.

import 'dart:convert';

import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';
import 'package:chuk_chat/services/tool_result_cache_registry.dart';
import 'package:chuk_chat/services/websocket_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _imgA = 'data:image/png;base64,AAAA';
const _imgB = 'data:image/jpeg;base64,BBBB';

Map<String, dynamic> _call(String id) => {
  'role': 'assistant',
  'content': '',
  'tool_calls': [
    {
      'id': id,
      'type': 'function',
      'function': {'name': 'calc', 'arguments': '{}'},
    },
  ],
};

Map<String, dynamic> _result(String id) => {
  'role': 'tool',
  'tool_call_id': id,
  'content': 'ok',
};

List<Map<String, dynamic>> _loop(List<Object> turnContent) => [
  {'role': 'user', 'content': 'older'},
  {'role': 'assistant', 'content': 'older answer'},
  {'role': 'user', 'content': turnContent},
  _call('c1'),
  _result('c1'),
  {'role': 'user', 'content': skillContentMessage('s', 'body')},
  _call('c2'),
  _result('c2'),
];

void main() {
  final registry = ToolResultCacheRegistry.instance;
  setUp(registry.clear);
  tearDown(registry.clear);

  test('the loop anchor is the user turn before the first call', () {
    final history = _loop(userContentWithImages('look', const [_imgA]));
    expect(WebSocketChatService.toolLoopTurnIndex(history), 2);
    expect(
      WebSocketChatService.toolLoopTurnIndex(history.sublist(0, 2)),
      isNull,
    );
  });

  test('all images cached: refs in order, entry keeps its text', () {
    final idA = registry.registerImage(_imgA);
    final idB = registry.registerImage(_imgB);
    final history = _loop(
      userContentWithImages('[Sent: Wed 2026-11-04 14:32]\nlook', const [
        _imgA,
        _imgB,
      ]),
    );
    final folded = WebSocketChatService.foldTurnImageRefs(
      history,
      '',
      registry,
    )!;
    expect(folded.refs, [idA, idB]);
    expect(folded.history[2], {
      'role': 'user',
      'content': '[Sent: Wed 2026-11-04 14:32]\nlook',
    });
    // Nothing else changes, and the input is not touched.
    for (final i in [0, 1, 3, 4, 5, 6, 7]) {
      expect(folded.history[i], same(history[i]));
    }
    expect(history[2]['content'], isA<List>());
  });

  test('stays in full when it cannot be byte-identical', () {
    registry.registerImage(_imgA);
    final withImage = _loop(userContentWithImages('look', const [_imgA]));
    // A prompt-based pass sends a message: the server would put the images
    // on a new user turn.
    expect(
      WebSocketChatService.foldTurnImageRefs(withImage, 'results', registry),
      isNull,
    );
    // One image not cached.
    expect(
      WebSocketChatService.foldTurnImageRefs(
        _loop(userContentWithImages('look', const [_imgA, _imgB])),
        '',
        registry,
      ),
      isNull,
    );
    // Image-only turn: the server would drop the empty entry.
    expect(
      WebSocketChatService.foldTurnImageRefs(
        _loop(userContentWithImages('', const [_imgA])),
        '',
        registry,
      ),
      isNull,
    );
    // Text after an image.
    expect(
      WebSocketChatService.foldTurnImageRefs(
        _loop([
          ...userContentWithImages('look', const [_imgA]),
          {'type': 'text', 'text': '[image omitted: x]'},
        ]),
        '',
        registry,
      ),
      isNull,
    );
    // Not a native tool loop.
    expect(
      WebSocketChatService.foldTurnImageRefs(
        withImage.sublist(0, 3),
        '',
        registry,
      ),
      isNull,
    );
    // After a server cache miss refs pause.
    registry.handleMiss();
    registry.registerImage(_imgA);
    expect(
      WebSocketChatService.foldTurnImageRefs(withImage, '', registry),
      isNull,
    );
  });

  test('several text parts stay a list', () {
    final id = registry.registerImage(_imgA);
    final folded = WebSocketChatService.foldTurnImageRefs(
      _loop([
        {'type': 'text', 'text': '[image omitted: old.png]'},
        ...userContentWithImages('look', const [_imgA]),
      ]),
      '',
      registry,
    )!;
    expect(folded.refs, [id]);
    expect(folded.history[2]['content'], [
      {'type': 'text', 'text': '[image omitted: old.png]'},
      {'type': 'text', 'text': 'look'},
    ]);
  });

  group('the turn anchor', () {
    test('a skill body before the first call is not the turn', () {
      final history = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'older'},
        {'role': 'assistant', 'content': 'older answer'},
        {
          'role': 'user',
          'content': userContentWithImages('look', const [_imgA]),
        },
        {'role': 'user', 'content': skillContentMessage('s', 'body')},
        _call('c1'),
        _result('c1'),
      ];
      expect(WebSocketChatService.toolLoopTurnIndex(history), 2);
      expect(WebSocketChatService.turnAnchor(history, null), 2);
      // Only synthetic messages before the loop: no turn.
      expect(
        WebSocketChatService.toolLoopTurnIndex([
          {'role': 'assistant', 'content': 'a'},
          {'role': 'user', 'content': skillContentMessage('s', 'body')},
          _call('c1'),
          _result('c1'),
        ]),
        isNull,
      );
    });

    test('synthetic user messages', () {
      bool synthetic(Object content) =>
          WebSocketChatService.isSyntheticUserMessage({
            'role': 'user',
            'content': content,
          });
      expect(synthetic(skillContentMessage('s', 'b')), isTrue);
      expect(synthetic(skillDroppedMarker('s')), isTrue);
      expect(synthetic('Tool Results:\n[INFO] retry'), isTrue);
      expect(synthetic(kForcedFinalAnswerNote), isTrue);
      expect(
        synthetic([
          {'type': 'text', 'text': skillContentMessage('s', 'b')},
        ]),
        isTrue,
      );
      // A note heads the turn's own message: that message is the turn.
      expect(
        synthetic(
          renderUserTurnForModel(
            text: 'look',
            sentAt: '2026-11-04T14:32:00',
            notes: const ['[memory updated] new facts'],
          ),
        ),
        isFalse,
      );
      expect(synthetic('look'), isFalse);
    });

    test('a named turn wins over the rule, a bad name gives none', () {
      final history = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': userContentWithImages('look', const [_imgA]),
        },
        _call('c1'),
        _result('c1'),
        {'role': 'assistant', 'content': 'I will check.'},
        {'role': 'user', 'content': 'Tool Results:\n[INFO] no call'},
        _call('c2'),
        _result('c2'),
      ];
      // The rule stops at the assistant text; the loop's name does not.
      expect(WebSocketChatService.toolLoopTurnIndex(history), isNull);
      expect(WebSocketChatService.turnAnchor(history, 0), 0);
      expect(WebSocketChatService.turnAnchor(history, 3), isNull);
      expect(WebSocketChatService.turnAnchor(history, 99), isNull);
      final id = registry.registerImage(_imgA);
      final folded = WebSocketChatService.foldTurnImageRefs(
        history,
        '',
        registry,
        turnIndex: 0,
      )!;
      expect(folded.refs, [id]);
      expect(folded.history[0]['content'], 'look');
    });

    test('text parts keep their whitespace', () {
      registry.registerImage(_imgA);
      final folded = WebSocketChatService.foldTurnImageRefs(
        _loop([
          {'type': 'text', 'text': 'hello '},
          {'type': 'text', 'text': ' world'},
          ...userContentWithImages('', const [_imgA]),
        ]),
        '',
        registry,
      )!;
      expect(folded.history[2]['content'], [
        {'type': 'text', 'text': 'hello '},
        {'type': 'text', 'text': ' world'},
      ]);
    });

    test('pass N is a byte prefix of pass N+1 with a skill body', () {
      final idA = registry.registerImage(_imgA);
      final idB = registry.registerImage(_imgB);
      const text = '[Sent: Wed 2026-11-04 14:32]\nlook';
      final older = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'older'},
        {'role': 'assistant', 'content': 'older answer'},
      ];
      // Pass 1: the turn as the server builds it from message + images.
      final pass1 = [
        ...older,
        {
          'role': 'user',
          'content': userContentWithImages(text, const [_imgA, _imgB]),
        },
      ];
      // Pass 2: the loop put the turn's images on its own entry; a skill
      // body sits between the turn and the first call.
      final step = [
        ...older,
        {
          'role': 'user',
          'content': userContentWithImages(text, const [_imgA, _imgB]),
        },
        {'role': 'user', 'content': skillContentMessage('s', 'body')},
        _call('c1'),
        _result('c1'),
      ];
      final index = WebSocketChatService.turnAnchor(step, 2)!;
      final folded = WebSocketChatService.foldTurnImageRefs(
        step,
        '',
        registry,
        turnIndex: index,
      )!;
      expect(folded.refs, [idA, idB]);
      // The server's attach_turn_images on turn_history_index: text, then
      // the images in ref order.
      final images = {idA: _imgA, idB: _imgB};
      final pass2 = List<Map<String, dynamic>>.of(folded.history);
      pass2[index] = {
        'role': 'user',
        'content': userContentWithImages(pass2[index]['content'] as String, [
          for (final ref in folded.refs) images[ref]!,
        ]),
      };
      final a = pass1.map(jsonEncode).join();
      final b = pass2.map(jsonEncode).join();
      expect(b.startsWith(a), isTrue);
      // The skill body is untouched and carries no image.
      expect(pass2[3], same(step[3]));
    });
  });

  // Earlier turns' images: a full block goes up once, tagged with a
  // `cache_id`; later requests send `image_ref`. The server
  // (`multiplex._history_image_refs`) stores tagged blocks, resolves refs to
  // the same `image_url` block and never sends `cache_id` upstream, so the
  // history it hands the provider is byte-identical either way
  // (api_server tests/test_history_image_refs.py).
  group('history image refs', () {
    // The server's image store, per user (tool_result_cache).
    late Map<String, String> serverStore;

    // The history the server sends upstream for [sent], or null on a
    // cache_miss. Mirrors `_history_image_refs`: store every tagged block
    // first, then resolve every ref; a block goes up as
    // {type: image_url, image_url: {url}}.
    List<Map<String, dynamic>>? serverHistory(
      List<Map<String, dynamic>> sent,
    ) {
      for (final entry in sent) {
        final content = entry['content'];
        if (entry['role'] != 'user' || content is! List) continue;
        for (final block in content) {
          if (block is Map &&
              block['type'] == 'image_url' &&
              block['cache_id'] is String) {
            serverStore[block['cache_id'] as String] =
                (block['image_url'] as Map)['url'] as String;
          }
        }
      }
      final out = <Map<String, dynamic>>[];
      for (final entry in sent) {
        final content = entry['content'];
        if (entry['role'] != 'user' || content is! List) {
          out.add(entry);
          continue;
        }
        final blocks = <Map<String, dynamic>>[];
        for (final block in content.cast<Map>()) {
          if (block['type'] == 'image_ref') {
            final url = serverStore[block['ref']];
            if (url == null || !url.startsWith('data:image/')) return null;
            blocks.add({
              'type': 'image_url',
              'image_url': {'url': url},
            });
          } else if (block['type'] == 'image_url') {
            blocks.add({'type': 'image_url', 'image_url': block['image_url']});
          } else {
            blocks.add(Map<String, dynamic>.from(block));
          }
        }
        out.add({...entry, 'content': blocks});
      }
      return out;
    }

    List<Map<String, dynamic>> chat(int turns) => [
      for (var t = 0; t < turns; t++) ...[
        {
          'role': 'user',
          'content': userContentWithImages('turn $t', [
            if (t == 0) _imgA,
            if (t == 1) _imgB,
          ]),
        },
        {'role': 'assistant', 'content': 'answer $t'},
      ],
    ];

    setUp(() => serverStore = <String, String>{});

    test('first request tags, later requests ref, upstream bytes equal', () {
      // Turn 2: both images go up in full, tagged.
      final full2 = chat(2);
      final sent2 = WebSocketChatService.foldHistoryImageRefs(full2, registry);
      final blocks2 = [
        for (final e in sent2)
          if (e['content'] is List) ...(e['content'] as List).cast<Map>(),
      ].where((b) => b['type'] != 'text').toList();
      expect(blocks2.every((b) => b['cache_id'] is String), isTrue);
      expect(jsonEncode(serverHistory(sent2)), jsonEncode(full2));

      // Turn 3: the same images go as refs, a few bytes each.
      final full3 = chat(3);
      final sent3 = WebSocketChatService.foldHistoryImageRefs(full3, registry);
      final blocks3 = [
        for (final e in sent3)
          if (e['content'] is List) ...(e['content'] as List).cast<Map>(),
      ].where((b) => b['type'] != 'text').toList();
      expect(blocks3.map((b) => b['type']), ['image_ref', 'image_ref']);
      expect(jsonEncode(sent3), isNot(contains('base64')));
      final upstream3 = serverHistory(sent3)!;
      expect(jsonEncode(upstream3), jsonEncode(full3));
      // And turn 2's upstream history is a byte prefix of turn 3's.
      final a = serverHistory(sent2)!.map(jsonEncode).join();
      expect(upstream3.map(jsonEncode).join().startsWith(a), isTrue);
      // The input is never changed in place.
      expect(jsonEncode(full3), contains(_imgA));
    });

    test('a miss clears the registry; the retry goes in full, tagged', () {
      final full = chat(3);
      WebSocketChatService.foldHistoryImageRefs(full, registry);
      serverStore.clear(); // expired on the server (other replica, LRU)
      final sent = WebSocketChatService.foldHistoryImageRefs(full, registry);
      expect(serverHistory(sent), isNull); // the server answers cache_miss
      registry.handleMiss();
      final retry = WebSocketChatService.foldHistoryImageRefs(full, registry);
      expect(jsonEncode(retry), isNot(contains('image_ref')));
      expect(jsonEncode(serverHistory(retry)), jsonEncode(full));
    });

    test('the same image twice: stored and used in one request', () {
      final full = [
        {
          'role': 'user',
          'content': userContentWithImages('twice', const [_imgA, _imgA]),
        },
        {'role': 'assistant', 'content': 'ok'},
      ];
      final sent = WebSocketChatService.foldHistoryImageRefs(full, registry);
      final parts = (sent[0]['content'] as List).cast<Map>();
      expect(parts[1]['cache_id'], isA<String>());
      expect(parts[2], {'type': 'image_ref', 'ref': parts[1]['cache_id']});
      expect(jsonEncode(serverHistory(sent)), jsonEncode(full));
    });

    test('only plain data-URL blocks of user turns are folded', () {
      final odd = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'x'},
            {
              'type': 'image_url',
              'image_url': {'url': _imgA, 'detail': 'high'},
            },
            {
              'type': 'image_url',
              'image_url': {'url': 'https://example.com/a.png'},
            },
          ],
        },
        {
          'role': 'tool',
          'tool_call_id': 't',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': _imgB},
            },
          ],
        },
      ];
      final sent = WebSocketChatService.foldHistoryImageRefs(odd, registry);
      expect(identical(sent, odd), isTrue);
      expect(registry.imageCount, 0);
    });

    test("the turn's own refs and history refs share one image id", () {
      // Pass 1 sent the turn's image in full with an image_cache_ids id;
      // the next turn's history refs it by that id.
      final id = registry.registerImage(_imgA);
      final sent = WebSocketChatService.foldHistoryImageRefs(chat(2), registry);
      expect((sent[0]['content'] as List)[1], {'type': 'image_ref', 'ref': id});
    });
  });
}
