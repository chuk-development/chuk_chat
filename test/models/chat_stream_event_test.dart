import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/chat_stream_event.dart';

void main() {
  group('ContentEvent', () {
    test('construction', () {
      const event = ContentEvent('Hello world');
      expect(event.text, equals('Hello world'));
    });

    test('is ChatStreamEvent', () {
      const event = ContentEvent('text');
      expect(event, isA<ChatStreamEvent>());
    });

    test('factory constructor', () {
      const event = ChatStreamEvent.content('chunk');
      expect(event, isA<ContentEvent>());
      expect((event as ContentEvent).text, equals('chunk'));
    });

    test('empty text', () {
      const event = ContentEvent('');
      expect(event.text, isEmpty);
    });
  });

  group('ReasoningEvent', () {
    test('construction', () {
      const event = ReasoningEvent('thinking...');
      expect(event.text, equals('thinking...'));
    });

    test('factory constructor', () {
      const event = ChatStreamEvent.reasoning('step 1');
      expect(event, isA<ReasoningEvent>());
    });
  });

  group('UsageEvent', () {
    test('construction', () {
      const usage = {'prompt_tokens': 100, 'completion_tokens': 50};
      const event = UsageEvent(usage);
      expect(event.usage['prompt_tokens'], equals(100));
      expect(event.usage['completion_tokens'], equals(50));
    });

    test('factory constructor', () {
      const event = ChatStreamEvent.usage({'tokens': 42});
      expect(event, isA<UsageEvent>());
    });
  });

  group('MetaEvent', () {
    test('construction', () {
      const meta = {'model': 'gpt-4', 'provider': 'openai'};
      const event = MetaEvent(meta);
      expect(event.meta['model'], equals('gpt-4'));
    });

    test('factory constructor', () {
      const event = ChatStreamEvent.meta({'key': 'value'});
      expect(event, isA<MetaEvent>());
    });
  });

  group('TpsEvent', () {
    test('construction', () {
      const event = TpsEvent(45.5);
      expect(event.tokensPerSecond, equals(45.5));
    });

    test('factory constructor', () {
      const event = ChatStreamEvent.tps(100.0);
      expect(event, isA<TpsEvent>());
      expect((event as TpsEvent).tokensPerSecond, equals(100.0));
    });

    test('zero tps', () {
      const event = TpsEvent(0.0);
      expect(event.tokensPerSecond, equals(0.0));
    });
  });

  group('ErrorEvent', () {
    test('construction', () {
      const event = ErrorEvent('Connection lost');
      expect(event.message, equals('Connection lost'));
    });

    test('factory constructor', () {
      const event = ChatStreamEvent.error('timeout');
      expect(event, isA<ErrorEvent>());
      expect((event as ErrorEvent).message, equals('timeout'));
    });
  });

  group('DoneEvent', () {
    test('construction', () {
      const event = DoneEvent();
      expect(event, isA<ChatStreamEvent>());
    });

    test('factory constructor', () {
      const event = ChatStreamEvent.done();
      expect(event, isA<DoneEvent>());
    });
  });

  group('pattern matching', () {
    test('switch on all event types', () {
      final events = <ChatStreamEvent>[
        const ContentEvent('text'),
        const ReasoningEvent('reason'),
        const UsageEvent({'tokens': 1}),
        const MetaEvent({'key': 'val'}),
        const TpsEvent(50.0),
        const ErrorEvent('err'),
        const DoneEvent(),
      ];

      final types = <String>[];
      for (final event in events) {
        switch (event) {
          case ContentEvent():
            types.add('content');
          case ReasoningEvent():
            types.add('reasoning');
          case UsageEvent():
            types.add('usage');
          case MetaEvent():
            types.add('meta');
          case TpsEvent():
            types.add('tps');
          case ErrorEvent():
            types.add('error');
          case DoneEvent():
            types.add('done');
        }
      }

      expect(types, equals([
        'content', 'reasoning', 'usage', 'meta', 'tps', 'error', 'done',
      ]));
    });
  });
}
