import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'same model retains different providers per chat across restart',
    () async {
      final original = ChatModelSelectionService();
      await original.save(
        'chat-a',
        const ChatModelSelection(modelId: 'm', providerSlug: 'p1'),
        userId: 'u',
      );
      await original.save(
        'chat-b',
        const ChatModelSelection(modelId: 'm', providerSlug: 'p2'),
        userId: 'u',
      );
      final restarted = ChatModelSelectionService();
      expect((await restarted.load('chat-a', userId: 'u'))!.providerSlug, 'p1');
      expect((await restarted.load('chat-b', userId: 'u'))!.providerSlug, 'p2');
      expect(await restarted.load('chat-a', userId: 'other-user'), isNull);
    },
  );

  test('legacy chat preserves explicit caller defaults', () async {
    final choice = await ChatModelSelectionService().resolveForSend(
      'legacy',
      modelId: 'default-model',
      providerSlug: 'default-provider',
      userId: 'u',
    );
    expect(choice.modelId, 'default-model');
    expect(choice.providerSlug, 'default-provider');
  });

  test('send snapshot is immutable while another selection is saved', () async {
    final store = ChatModelSelectionService();
    await store.save(
      'a',
      const ChatModelSelection(modelId: 'm', providerSlug: 'p1'),
      userId: 'u',
    );
    final captured = store.resolveForSend(
      'a',
      modelId: 'global',
      providerSlug: 'global',
      userId: 'u',
    );
    await store.save(
      'a',
      const ChatModelSelection(modelId: 'm', providerSlug: 'p2'),
      userId: 'u',
    );
    expect((await captured).providerSlug, 'p1');
    expect((await store.load('a', userId: 'u'))!.providerSlug, 'p2');
  });

  test('invalid selection cannot poison the chat route', () async {
    final store = ChatModelSelectionService();
    await expectLater(
      store.save('a', const ChatModelSelection(modelId: '', providerSlug: 'p')),
      throwsArgumentError,
    );
    expect(await store.load('a'), isNull);
  });

  test('automatic-provider marker cannot be persisted as a wire provider', () async {
    await expectLater(ChatModelSelectionService().save('a',
      const ChatModelSelection(modelId: 'm', providerSlug: '__auto_cheapest__')),
      throwsArgumentError);
  });

  test('cold load notifies settings and concurrent saves persist in order', () async {
    final store = ChatModelSelectionService();
    final first = store.save('a', const ChatModelSelection(modelId: 'm', providerSlug: 'one'));
    final second = store.save('a', const ChatModelSelection(modelId: 'm', providerSlug: 'two'));
    await Future.wait([first, second]);
    expect(store.peek('a')!.providerSlug, 'two');
    final restarted = ChatModelSelectionService();
    var notifications = 0;
    restarted.addListener(() => notifications++);
    expect((await restarted.load('a'))!.providerSlug, 'two');
    expect(notifications, 1);
  });

  test('a coworker keeps its reasoning level with its model', () async {
    final store = ChatModelSelectionService();
    await store.save(
      'coworker',
      const ChatModelSelection(
        modelId: 'm',
        providerSlug: 'p',
        reasoningEffort: 'high',
      ),
      userId: 'u',
    );
    final restarted = ChatModelSelectionService();
    final choice = await restarted.load('coworker', userId: 'u');
    expect(choice!.reasoningEffort, 'high');
    final route = await restarted.resolveForSend(
      'coworker',
      modelId: 'composer-model',
      providerSlug: 'composer-provider',
      userId: 'u',
    );
    expect(route.reasoningEffort, 'high');
  });

  test('a record written before the level existed reads without one', () {
    final choice = ChatModelSelection.fromJson(<String, Object>{
      'modelId': 'm',
      'providerSlug': 'p',
    });
    expect(choice!.reasoningEffort, isNull);
    expect(choice.toJson().containsKey('reasoningEffort'), isFalse);
  });

  test('clearing the own model makes the chat follow the default', () async {
    final store = ChatModelSelectionService();
    await store.save(
      'coworker',
      const ChatModelSelection(modelId: 'm', providerSlug: 'p'),
      userId: 'u',
    );
    var notifications = 0;
    store.addListener(() => notifications++);
    await store.clear('coworker', userId: 'u');
    expect(notifications, 1);
    expect(store.peek('coworker', userId: 'u'), isNull);
    final restarted = ChatModelSelectionService();
    expect(await restarted.load('coworker', userId: 'u'), isNull);
    final route = await restarted.resolveForSend(
      'coworker',
      modelId: 'default-model',
      providerSlug: 'default-provider',
      userId: 'u',
    );
    expect(route.modelId, 'default-model');
    expect(route.reasoningEffort, isNull);
  });
}
