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
    MessageFeedbackStore.removeFromBackend = null;
    MessageFeedbackStore.userIdReader = () => null;
  });

  // L6: verdicts are kept per user and leave the device at sign-out.
  test('verdicts are per user and go at sign-out', () async {
    String? user = 'user-a';
    MessageFeedbackStore.userIdReader = () => user;
    await store.save(_fb('a1'));
    user = 'user-b';
    await store.ensureLoaded();
    expect(store.peek('a1'), isNull);
    await store.save(_fb('b1'));
    user = 'user-a';
    await store.ensureLoaded();
    expect(store.peek('a1'), isNotNull);
    expect(store.peek('b1'), isNull);
    await store.clearForSignOut('user-a');
    expect(store.peek('a1'), isNull);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(MessageFeedbackStore.prefsKeyFor('user-a')), isNull);
    expect(
      prefs.getString(MessageFeedbackStore.prefsKeyFor('user-b')),
      isNotNull,
    );
  });

  test('old unowned verdicts go to the first signed-in user only', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      MessageFeedbackStore.prefsKey: jsonEncode(<Object>[_fb('old').toJson()]),
    });
    MessageFeedbackStore.userIdReader = () => 'user-a';
    await store.ensureLoaded();
    expect(store.peek('old'), isNotNull);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(MessageFeedbackStore.prefsKey), isNull);
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
      prefs.getString(MessageFeedbackStore.prefsKeyFor(null))!,
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
