// StreamingManager error paths: out of credits (B6), an upstream break
// (B2/B3), the finish_reason meta merge (B4) and the Agents close path.

import 'dart:async';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/streaming_manager.dart';
import 'package:chuk_chat/services/streaming_manager_base.dart'
    show kPaymentRequiredError;
import 'package:chuk_chat/services/tool_call_handler.dart' show ToolTurnSignals;
import 'package:flutter_test/flutter_test.dart';

class _Run {
  final controller = StreamController<ChatStreamEvent>();
  final errors = <String>[];
  final codes = <String?>[];
  final completions = <String>[];
}

void main() {
  final manager = StreamingManager();

  tearDown(() async {
    debugAgentsChatCoreOverride = null;
    await manager.cancelAllStreams();
  });

  Future<_Run> start(String chatId) async {
    final run = _Run();
    await manager.startStream(
      chatId: chatId,
      messageIndex: 0,
      stream: run.controller.stream,
      onUpdate: (_, _) {},
      onComplete: (content, _, _) => run.completions.add(content),
      onError: (message, {String? code}) {
        run.errors.add(message);
        run.codes.add(code);
      },
    );
    return run;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('B6: out of credits shows the upgrade dialog', () {
    test('code billing maps to the payment-required error', () async {
      final run = await start('billing-code');
      run.controller.add(
        const ErrorEvent('Insufficient credits.', code: 'billing'),
      );
      await settle();
      expect(run.errors, [kPaymentRequiredError]);
      expect(run.codes, [StreamErrorCodes.billing]);
      expect(StreamErrorCodes.retryable, isNot(contains('billing')));
    });

    test('class quota maps to the payment-required error', () async {
      final run = await start('billing-class');
      run.controller.add(
        const ErrorEvent('Out of quota.', code: 'x', errorClass: 'quota'),
      );
      await settle();
      expect(run.errors, [kPaymentRequiredError]);
    });

    test('other errors keep their text and code', () async {
      final run = await start('other-error');
      run.controller.add(
        const ErrorEvent(
          'Too many requests.',
          code: 'rate_limited',
          errorClass: 'rate_limit',
        ),
      );
      await settle();
      expect(run.errors, ['Too many requests.']);
      expect(run.codes, ['rate_limited']);
    });
  });

  group('B2/B3: a cut stream is an error, its text is kept', () {
    test(
      'upstream_interrupted parks the partial text and is retryable',
      () async {
        final run = await start('upstream-cut');
        run.controller.add(const ContentEvent('half of '));
        run.controller.add(const ContentEvent('it'));
        run.controller.add(
          const ErrorEvent(
            'The AI service stopped mid-answer.',
            code: StreamErrorCodes.upstreamInterrupted,
          ),
        );
        await settle();
        expect(run.completions, isEmpty);
        expect(run.codes, [StreamErrorCodes.upstreamInterrupted]);
        expect(manager.takeInterruptedPartial('upstream-cut'), 'half of it');
        expect(
          StreamErrorCodes.retryable,
          containsAll([
            StreamErrorCodes.upstreamInterrupted,
            StreamErrorCodes.streamInterrupted,
          ]),
        );
      },
    );

    test('a close without done is stream_interrupted', () async {
      final run = await start('closed-early');
      run.controller.add(const ContentEvent('partial'));
      await settle();
      await run.controller.close();
      await settle();
      expect(run.completions, isEmpty);
      expect(run.codes, [StreamErrorCodes.streamInterrupted]);
      expect(manager.takeInterruptedPartial('closed-early'), 'partial');
    });

    test('a clean done still completes and parks nothing', () async {
      final run = await start('clean');
      run.controller.add(const ContentEvent('full answer'));
      run.controller.add(const DoneEvent());
      await settle();
      await run.controller.close();
      await settle();
      expect(run.completions, ['full answer']);
      expect(run.errors, isEmpty);
      expect(manager.takeInterruptedPartial('clean'), isNull);
    });

    test('an Agents thread closing without done still completes', () async {
      debugAgentsChatCoreOverride = true;
      final run = await start('amber-otter-2');
      run.controller.add(const ContentEvent('host text'));
      await settle();
      await run.controller.close();
      await settle();
      expect(run.completions, ['host text']);
      expect(run.errors, isEmpty);
    });

    test('a new stream clears a stale partial of the same chat', () async {
      final first = await start('stale');
      first.controller.add(const ContentEvent('old'));
      await settle();
      await first.controller.close();
      await settle();
      await start('stale');
      expect(manager.takeInterruptedPartial('stale'), isNull);
    });
  });

  test(
    'B4: meta frames merge, so finish_reason reaches the tool loop',
    () async {
      final run = await start('meta-merge');
      run.controller.add(const MetaEvent({'model': 'm', 'provider': 'p'}));
      run.controller.add(const MetaEvent({'finish_reason': 'length'}));
      run.controller.add(const DoneEvent());
      await settle();
      final meta = manager.getLatestMeta('meta-merge')!;
      expect(meta['model'], 'm');
      expect(meta['finish_reason'], 'length');
      expect(ToolTurnSignals.fromMeta(meta).indicatesTruncated, isTrue);
    },
  );
}
