import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_protocol.dart';

class _FakeDelegate implements VoiceTaskDelegate {
  _FakeDelegate({this.onStart});

  final Future<String> Function(String task)? onStart;
  final List<String> started = <String>[];
  final StreamController<VoiceTaskResult> _results =
      StreamController<VoiceTaskResult>.broadcast();

  @override
  Future<String> startTask(String task) {
    started.add(task);
    return onStart?.call(task) ??
        Future<String>.value('task-${started.length}');
  }

  @override
  Stream<VoiceTaskResult> get results => _results.stream;
}

Map<String, dynamic> _json(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('chuk.delegate', () {
    test('no delegate answers "no delegate"', () async {
      final String answer = await VoiceProtocol.handleDelegate(
        jsonEncode(<String, dynamic>{'task': 'buy milk'}),
        null,
      );
      expect(_json(answer), <String, dynamic>{'error': 'no delegate'});
    });

    test('starts the task and answers its id at once', () async {
      final _FakeDelegate delegate = _FakeDelegate();
      final String answer = await VoiceProtocol.handleDelegate(
        jsonEncode(<String, dynamic>{'task': '  add milk to my list  '}),
        delegate,
      );
      expect(_json(answer), <String, dynamic>{
        'task_id': 'task-1',
        'status': 'started',
      });
      expect(delegate.started, <String>['add milk to my list']);
    });

    test('a missing, empty or non-string task is an error', () async {
      final _FakeDelegate delegate = _FakeDelegate();
      for (final String payload in <String>[
        '{}',
        '{"task": ""}',
        '{"task": 42}',
        'not json',
        '[1,2]',
      ]) {
        final String answer = await VoiceProtocol.handleDelegate(
          payload,
          delegate,
        );
        expect(_json(answer), <String, dynamic>{'error': 'missing task'});
      }
      expect(delegate.started, isEmpty);
    });

    test('a delegate that throws answers the error', () async {
      final _FakeDelegate delegate = _FakeDelegate(
        onStart: (_) => Future<String>.error(StateError('host offline')),
      );
      final String answer = await VoiceProtocol.handleDelegate(
        '{"task":"x"}',
        delegate,
      );
      expect(_json(answer)['error'], contains('host offline'));
    });

    test(
      'a delegate slower than the timeout answers a timeout error',
      () async {
        final _FakeDelegate delegate = _FakeDelegate(
          onStart: (_) => Completer<String>().future,
        );
        final String answer = await VoiceProtocol.handleDelegate(
          '{"task":"x"}',
          delegate,
          timeout: const Duration(milliseconds: 20),
        );
        expect(_json(answer), <String, dynamic>{'error': 'delegate timed out'});
      },
    );

    test('a task whose chat closed while it started is refused', () async {
      final _FakeDelegate delegate = _FakeDelegate();
      final List<String> seen = <String>[];
      final String answer = await VoiceProtocol.handleDelegate(
        '{"task":"x"}',
        delegate,
        onStarted: (String id) {
          seen.add(id);
          return false;
        },
      );
      expect(seen, <String>['task-1']);
      expect(_json(answer), <String, dynamic>{'error': 'the chat was closed'});
    });

    test('onStarted true keeps the started answer', () async {
      final String answer = await VoiceProtocol.handleDelegate(
        '{"task":"x"}',
        _FakeDelegate(),
        onStarted: (_) => true,
      );
      expect(_json(answer)['status'], 'started');
    });

    test('answers before the worker gives up (10 s)', () {
      expect(
        VoiceProtocol.delegateAnswerTimeout,
        lessThan(const Duration(seconds: 10)),
      );
    });
  });

  group('chuk.task_result', () {
    test('carries task_id, status and result', () {
      final Map<String, dynamic> payload = _json(
        VoiceProtocol.taskResultPayload(
          const VoiceTaskResult(taskId: 't1', status: 'done', result: 'Milch'),
        ),
      );
      expect(payload, <String, dynamic>{
        'task_id': 't1',
        'status': 'done',
        'result': 'Milch',
      });
    });

    test('an unknown status is sent as failed', () {
      final Map<String, dynamic> payload = _json(
        VoiceProtocol.taskResultPayload(
          const VoiceTaskResult(taskId: 't', status: 'weird', result: ''),
        ),
      );
      expect(payload['status'], 'failed');
    });

    test('the result is cut to 6000 characters', () {
      final String long = 'a' * 9000;
      final Map<String, dynamic> payload = _json(
        VoiceProtocol.taskResultPayload(
          VoiceTaskResult(taskId: 't', status: 'done', result: long),
        ),
      );
      expect((payload['result'] as String).length, 6000);
    });

    test('a multi-byte result stays under the RPC byte cap', () {
      // 6000 emoji = 24 000 UTF-8 bytes: fits the rune cut, not the byte cap.
      final String emoji = '😀' * 7000;
      final String wire = VoiceProtocol.taskResultPayload(
        VoiceTaskResult(taskId: 't', status: 'done', result: emoji),
      );
      expect(
        utf8.encode(wire).length,
        lessThanOrEqualTo(VoiceProtocol.maxRpcPayloadBytes),
      );
      final String result = _json(wire)['result'] as String;
      expect(result.runes.length, greaterThan(3000));
      // Never split a surrogate pair.
      expect(result.runes.every((int r) => r == '😀'.runes.first), isTrue);
    });
  });

  group('truncateRunes', () {
    test('keeps short text as is', () {
      expect(truncateRunes('abc', 5), 'abc');
    });

    test('cuts by code point, not by UTF-16 unit', () {
      expect(truncateRunes('😀😀😀', 2), '😀😀');
      expect(truncateRunes('ab😀cd', 3), 'ab😀');
    });

    test('zero or less is empty', () {
      expect(truncateRunes('abc', 0), '');
      expect(truncateRunes('abc', -1), '');
    });
  });

  group('dispatch metadata and token request', () {
    test('metadata has every key the worker reads', () {
      final Map<String, dynamic> meta = VoiceProtocol.dispatchMetadata(
        userId: 'u-1',
        mode: VoiceCallMode.agents,
        chatTitle: 'Einkauf',
        agentName: 'Mo',
        context: '  ${'x' * 5000}  ',
        sttLanguage: 'de',
        delegateAvailable: true,
      );
      expect(meta.keys.toSet(), <String>{
        'user_id',
        'mode',
        'chat_title',
        'agent_name',
        'context',
        'stt_language',
        'delegate_available',
        'voice_id',
        'llm_model',
        'initiated_by',
        'call_id',
        'call_reason',
      });
      expect(meta['mode'], 'agents');
      expect((meta['context'] as String).length, 4000);
      expect(meta['delegate_available'], isTrue);
      expect(meta['voice_id'], isNull);
      expect(meta['llm_model'], isNull);
      expect(meta['initiated_by'], 'user');
      expect(meta['call_id'], isNull);
    });

    test('an agent-started call carries its id and reason', () {
      final Map<String, dynamic> meta = VoiceProtocol.dispatchMetadata(
        userId: 'u',
        mode: VoiceCallMode.chat,
        delegateAvailable: false,
        initiatedByAgent: true,
        callId: 'call-9',
        callReason: 'pizza',
      );
      expect(meta['initiated_by'], 'agent');
      expect(meta['call_id'], 'call-9');
      expect(meta['call_reason'], 'pizza');
      expect(meta['mode'], 'chat');
      expect(meta['delegate_available'], isFalse);
    });

    test('STT language: the asked one, else the device language', () {
      expect(VoiceProtocol.resolveSttLanguage('en', 'de'), 'en');
      expect(VoiceProtocol.resolveSttLanguage(null, 'de'), 'de');
      expect(VoiceProtocol.resolveSttLanguage('  ', 'DE'), 'de');
      expect(VoiceProtocol.resolveSttLanguage(null, 'und'), isNull);
      expect(VoiceProtocol.resolveSttLanguage(null, ''), isNull);
      expect(VoiceProtocol.resolveSttLanguage(null, null), isNull);
    });

    test('token request matches the token server contract', () {
      final Map<String, dynamic> body = VoiceProtocol.tokenRequest(
        roomName: 'chuk-voice-1',
        participantIdentity: 'chuk-u',
        participantName: 'chuk-u',
        metadata: <String, dynamic>{'user_id': 'u'},
      );
      expect(body['room_name'], 'chuk-voice-1');
      expect(body['participant_identity'], 'chuk-u');
      expect(body['participant_name'], 'chuk-u');
      final List<dynamic> agents =
          (body['room_config'] as Map<String, dynamic>)['agents']
              as List<dynamic>;
      final Map<String, dynamic> agent = agents.single as Map<String, dynamic>;
      expect(agent['agent_name'], 'chuk-voice');
      // Metadata travels as a JSON string, not as an object.
      expect(agent['metadata'], isA<String>());
      expect(jsonDecode(agent['metadata'] as String), <String, dynamic>{
        'user_id': 'u',
      });
    });

    test('token response: snake_case, camelCase, and missing fields', () {
      final VoiceCredentials a = VoiceProtocol.parseTokenResponse(
        '{"server_url":"wss://x","participant_token":"t","room_name":"r"}',
      );
      expect(a.serverUrl, 'wss://x');
      expect(a.participantToken, 't');
      final VoiceCredentials b = VoiceProtocol.parseTokenResponse(
        '{"serverUrl":"wss://y","participantToken":"u"}',
      );
      expect(b.serverUrl, 'wss://y');
      expect(
        () => VoiceProtocol.parseTokenResponse('{"server_url":"wss://x"}'),
        throwsFormatException,
      );
      expect(
        () => VoiceProtocol.parseTokenResponse('[]'),
        throwsFormatException,
      );
    });
  });

  group('device tools', () {
    test('open_link opens web links only', () {
      expect(
        VoiceProtocol.openLinkTarget('{"url":"https://chuk.chat/x"}'),
        Uri.parse('https://chuk.chat/x'),
      );
      expect(
        VoiceProtocol.openLinkTarget('{"url":"http://example.com"}'),
        isNotNull,
      );
      for (final String bad in <String>[
        '{"url":"intent://scan/#Intent;end"}',
        '{"url":"tel:+491234"}',
        '{"url":"file:///etc/passwd"}',
        '{"url":"javascript:alert(1)"}',
        '{"url":""}',
        '{}',
        'junk',
      ]) {
        expect(VoiceProtocol.openLinkTarget(bad), isNull, reason: bad);
      }
    });

    test('location and device status are not offered', () {
      expect(_json(VoiceProtocol.notAvailable()), <String, dynamic>{
        'error': 'not available',
      });
      expect(
        VoiceProtocol.appMethods,
        containsAll(<String>[
          'chuk.delegate',
          'open_link',
          'get_location',
          'get_device_status',
        ]),
      );
    });

    test('open_link answers ok, with an error only when there is one', () {
      expect(_json(VoiceProtocol.openLinkAnswer(ok: true)), <String, dynamic>{
        'ok': true,
      });
      expect(
        _json(VoiceProtocol.openLinkAnswer(ok: false, error: 'invalid url')),
        <String, dynamic>{'ok': false, 'error': 'invalid url'},
      );
    });
  });

  group('ui.card / ui.tool', () {
    List<int> bytes(Object json) => utf8.encode(jsonEncode(json));

    test('a v1 card parses', () {
      final VoiceCard? card = VoiceProtocol.parseCard(
        bytes(<String, dynamic>{
          'v': 1,
          'id': 'c1',
          'kind': 'search',
          'title': 'Treffer',
          'data': <String, dynamic>{'answer': 'Ja'},
        }),
        at: DateTime.utc(2026, 9, 29),
      );
      expect(card, isNotNull);
      expect(card!.kind, 'search');
      expect(card.text('answer'), 'Ja');
      expect(card.at.isAtSameMomentAs(DateTime.utc(2026, 9, 29)), isTrue);
    });

    test('another version, no id or kind, or junk is dropped', () {
      expect(
        VoiceProtocol.parseCard(
          bytes(<String, dynamic>{'v': 2, 'id': 'c', 'kind': 'x'}),
        ),
        isNull,
      );
      expect(
        VoiceProtocol.parseCard(bytes(<String, dynamic>{'v': 1, 'kind': 'x'})),
        isNull,
      );
      expect(
        VoiceProtocol.parseCard(bytes(<String, dynamic>{'v': 1, 'id': 'c'})),
        isNull,
      );
      expect(VoiceProtocol.parseCard(<int>[0xff, 0xfe]), isNull);
    });

    test('a tool update parses, status defaults to running', () {
      final VoiceToolActivity? t = VoiceProtocol.parseToolActivity(
        bytes(<String, dynamic>{'v': 1, 'call_id': 'k', 'name': 'get_news'}),
      );
      expect(t, isNotNull);
      expect(t!.isRunning, isTrue);
      expect(t.label, 'Reading the news');
      expect(
        VoiceProtocol.parseToolActivity(bytes(<String, dynamic>{'v': 1})),
        isNull,
      );
    });
  });
}
