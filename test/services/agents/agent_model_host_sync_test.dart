// CHAT-36: an agent's own model is sent to the host, and a reinstalled app
// takes the host's stored model.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agent_model.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';

void main() {
  const chat = 'local:Mail:14:138509541';
  const flash = 'deepseek/deepseek-v4-flash-0731';
  final sent = <Map<String, dynamic>>[];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sent.clear();
    AgentModel.debugSendFrame = (payload) async => sent.add(payload);
  });

  tearDown(() => AgentModel.debugSendFrame = null);

  test('setOwn and useDefault send agent_model_set', () async {
    await AgentModel.setOwn(
      chat,
      modelId: flash,
      providerSlug: 'deepinfra',
      reasoningEffort: 'low',
    );
    await AgentModel.useDefault(chat);
    await pumpEventQueue();
    expect(sent.first['type'], 'agent_model_set');
    expect(sent.first['session_key'], chat);
    expect(sent.first['model'], flash);
    expect(sent.first['provider'], 'deepinfra');
    expect(sent.last['model'], isNull);
  });

  test(
    'adoptFromHost mirrors the host row, also over a stale record',
    () async {
      await AgentModel.adoptFromHost(chat, modelId: flash, providerSlug: 'x');
      final adopted = await ChatModelSelectionService.instance.load(chat);
      expect(adopted?.modelId, flash);
      expect(adopted?.providerSlug, 'x');

      // Changed on the host (another device): the local record follows.
      await AgentModel.adoptFromHost(
        chat,
        modelId: 'other/model',
        providerSlug: 'deepinfra',
      );
      final followed = await ChatModelSelectionService.instance.load(chat);
      expect(followed?.modelId, 'other/model');
      expect(followed?.providerSlug, 'deepinfra');

      // The default model on Auto (no provider) is the agent default: the
      // local record goes, and the settings show the default on Auto.
      await AgentModel.adoptFromHost(chat, modelId: AgentModel.defaultModelId);
      expect(await ChatModelSelectionService.instance.load(chat), isNull);
      final state = await AgentModel.resolveOrFallback(chat);
      expect(state.modelId, AgentModel.defaultModelId);
      expect(state.providerSlug, isEmpty);
      expect(sent, isEmpty, reason: 'adopting must not echo back to the host');
    },
  );

  test('status payload carries the stored source', () {
    final choice = AgentModelChoice.fromPayload(<String, dynamic>{
      'id': flash,
      'source': 'agent',
    });
    expect(choice?.isStored, isTrue);
    expect(
      AgentModelChoice.fromPayload(<String, dynamic>{'id': flash})?.isStored,
      isFalse,
    );
  });
}
