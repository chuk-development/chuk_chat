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
    final idA = registry.register(_imgA);
    final idB = registry.register(_imgB);
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
    registry.register(_imgA);
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
    registry.register(_imgA);
    expect(
      WebSocketChatService.foldTurnImageRefs(withImage, '', registry),
      isNull,
    );
  });

  test('several text parts stay a list', () {
    final id = registry.register(_imgA);
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
      final id = registry.register(_imgA);
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
      registry.register(_imgA);
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
      final idA = registry.register(_imgA);
      final idB = registry.register(_imgB);
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
}
