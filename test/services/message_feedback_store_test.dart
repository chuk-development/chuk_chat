import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/message_feedback_store.dart';

MessageFeedback _fb(String id, {FeedbackRating rating = FeedbackRating.up}) =>
    MessageFeedback(
      messageId: id,
      rating: rating,
      categories: const <FeedbackCategory>[
        FeedbackCategory.taskResult,
        FeedbackCategory.resourceCost,
      ],
      note: '  too slow  ',
      modelId: 'deepseek/deepseek-v4-flash-0731',
      createdAt: DateTime.utc(2026, 11, 4, 12),
    );

void main() {
  final MessageFeedbackStore store = MessageFeedbackStore.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store.resetForTest();
    MessageFeedbackStore.sendToBackend = null;
  });

  test('the seven category ids are the wire values', () {
    expect(FeedbackCategory.values.map((c) => c.id), <String>[
      'task-result',
      'instruction-following',
      'product-interaction',
      'service-stability',
      'resource-cost',
      'security-privacy-permission',
      'other',
    ]);
  });

  test('save, then a fresh load reads the same verdict', () async {
    await store.save(_fb('m1', rating: FeedbackRating.down));
    store.resetForTest();
    expect(store.peek('m1'), isNull);
    await store.ensureLoaded();
    final MessageFeedback? got = store.peek('m1');
    expect(got, isNotNull);
    expect(got!.rating, FeedbackRating.down);
    expect(got.categories, <FeedbackCategory>[
      FeedbackCategory.taskResult,
      FeedbackCategory.resourceCost,
    ]);
    expect(got.note, 'too slow');
    expect(got.modelId, 'deepseek/deepseek-v4-flash-0731');
  });

  test('a second verdict on one message replaces the first', () async {
    await store.save(_fb('m1'));
    await store.save(_fb('m1', rating: FeedbackRating.down));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<dynamic> rows = jsonDecode(
      prefs.getString(MessageFeedbackStore.prefsKey)!,
    ) as List<dynamic>;
    expect(rows, hasLength(1));
    expect(store.peek('m1')!.rating, FeedbackRating.down);
  });

  test('keeps only the newest maxEntries', () async {
    for (int i = 0; i < MessageFeedbackStore.maxEntries + 5; i++) {
      await store.save(_fb('m$i'));
    }
    store.resetForTest();
    await store.ensureLoaded();
    expect(store.peek('m0'), isNull);
    expect(store.peek('m4'), isNull);
    expect(store.peek('m5'), isNotNull);
    expect(store.peek('m${MessageFeedbackStore.maxEntries + 4}'), isNotNull);
  });

  test('sendToBackend gets the verdict when set', () async {
    final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
    MessageFeedbackStore.sendToBackend = (fb) async => sent.add(fb.toJson());
    await store.save(_fb('m1'));
    expect(sent.single['message_id'], 'm1');
    expect(sent.single['categories'], <String>['task-result', 'resource-cost']);
  });
}
