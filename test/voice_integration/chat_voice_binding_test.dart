import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/voice_task_delegates.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_turn_queue.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// A binding over a fake screen. No LiveKit: the test build has no token
/// server, so a started call fails at once, which is all these tests need.
ChatVoiceBinding _binding({
  required VoiceCallController controller,
  required String? Function() chatId,
  bool agents = false,
  List<String>? sent,
  bool Function()? busy,
  String? Function()? agentName,
}) => ChatVoiceBinding(
  controller: controller,
  currentChatId: chatId,
  isAgentsScreen: agents,
  agentName: agentName,
  isOffline: () => false,
  messages: () => <Map<String, String>>[
    <String, String>{'sender': 'user', 'text': 'hello'},
  ],
  isBusy: busy ?? () => false,
  send: (String text, VoiceTurnStarted onStarted) async {
    sent?.add(text);
  },
  onRecordsChanged: () {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the registry finds a screen by role and by its open chat', () {
    final VoiceCallController controller = VoiceCallController.forTesting();
    String? chatOpen = 'chat-a';
    String? threadOpen = 'thread-1';
    final ChatVoiceBinding chat = _binding(
      controller: controller,
      chatId: () => chatOpen,
    );
    final ChatVoiceBinding agents = _binding(
      controller: controller,
      chatId: () => threadOpen,
      agents: true,
    );
    final ChatVoiceSessions sessions = ChatVoiceSessions.instance;
    expect(sessions.forRole(agents: false), same(chat));
    expect(sessions.forRole(agents: true), same(agents));
    expect(sessions.forChat('thread-1'), same(agents));
    expect(sessions.forChat('chat-a'), same(chat));

    threadOpen = 'thread-2';
    chatOpen = null;
    expect(sessions.forChat('thread-1'), isNull);
    expect(sessions.forChat('thread-2'), same(agents));

    chat.dispose();
    agents.dispose();
    expect(sessions.forRole(agents: false), isNull);
    expect(sessions.forRole(agents: true), isNull);
  });

  test('a call starts for the chat on screen, and its panel belongs there', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final ChatVoiceBinding binding = _binding(
      controller: controller,
      chatId: () => 'chat-a',
    );
    await binding.startCall();
    // No token server in tests: the call fails, and says so in its panel.
    expect(controller.chatId, 'chat-a');
    expect(controller.mode, VoiceCallMode.chat);
    expect(controller.phase, VoiceCallPhase.failed);
    expect(binding.isLiveFor('chat-a'), isFalse);
    expect(binding.showsPanelFor('chat-a'), isTrue);
    expect(binding.showsPanelFor('chat-b'), isFalse);
    binding.dispose();
  });

  test('a new chat without an id cannot start a call', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final ChatVoiceBinding binding = _binding(
      controller: controller,
      chatId: () => null,
    );
    await binding.toggleCall();
    expect(controller.phase, VoiceCallPhase.idle);
    expect(binding.recordsFor(null), isEmpty);
    binding.dispose();
  });

  test('the panel follows the live call of its own chat only', () {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final ChatVoiceBinding binding = _binding(
      controller: controller,
      chatId: () => 'chat-a',
    );
    controller.debugSetState(
      phase: VoiceCallPhase.live,
      chatId: 'chat-a',
      mode: VoiceCallMode.chat,
    );
    expect(binding.isLiveFor('chat-a'), isTrue);
    expect(binding.showsPanelFor('chat-a'), isTrue);
    controller.debugSetState(phase: VoiceCallPhase.ended, chatId: 'chat-a');
    expect(binding.isLiveFor('chat-a'), isFalse);
    expect(binding.showsPanelFor('chat-a'), isFalse);
    binding.dispose();
  });

  test('dispose fails open tasks first, then closes: no dead delegate', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    bool busy = true; // the task stays queued
    final List<String> sent = <String>[];
    final ChatVoiceBinding binding = _binding(
      controller: controller,
      chatId: () => 'chat-a',
      busy: () => busy,
      sent: sent,
    );
    controller.debugSetState(phase: VoiceCallPhase.live, chatId: 'chat-a');
    final VoiceTurnDelegate delegate = binding.debugAdoptDelegate();
    final List<Object> events = <Object>[];
    delegate.results.listen(events.add, onDone: () => events.add('done'));
    final String id = await delegate.startTask('add milk');

    binding.dispose();
    await pumpEventQueue();
    expect(events, hasLength(2));
    final VoiceTaskResult result = events.first as VoiceTaskResult;
    expect(result.taskId, id);
    expect(result.status, VoiceTaskResult.statusFailed);
    expect(result.result, kVoiceTaskChatClosed);
    expect(events.last, 'done');
    await expectLater(delegate.startTask('more'), throwsStateError);

    busy = false;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(sent, isEmpty);
  });

  test('a hang-up cancels the tasks of that call that have not started', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    bool busy = true;
    final List<String> sent = <String>[];
    final ChatVoiceBinding binding = _binding(
      controller: controller,
      chatId: () => 'chat-a',
      busy: () => busy,
      sent: sent,
    );
    controller.debugSetState(phase: VoiceCallPhase.live, chatId: 'chat-a');
    final VoiceTurnDelegate delegate = binding.debugAdoptDelegate();
    await delegate.startTask('queued while the chat is busy');

    controller.debugSetState(phase: VoiceCallPhase.ended, chatId: 'chat-a');
    expect(delegate.isClosed, isTrue);
    busy = false;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // The chat never sends a task of a call that is over.
    expect(sent, isEmpty);
    binding.dispose();
  });

  test('the Agents screen names the coworker, not the thread title', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final List<VoiceCallStartProbe> starts = <VoiceCallStartProbe>[];
    debugOnVoiceCallStart = starts.add;
    addTearDown(() => debugOnVoiceCallStart = null);
    ChatOrigin.agentsEnabled = true;
    addTearDown(ChatOrigin.reset);
    final ChatVoiceBinding binding = _binding(
      controller: controller,
      chatId: () => 'host:thread-1',
      agents: true,
      agentName: () => 'Mira',
    );
    await binding.startCall();
    expect(starts.single.mode, VoiceCallMode.agents);
    expect(starts.single.agentName, 'Mira');
    // A name handed in by the caller still wins.
    await binding.startCall(agentName: 'Coworker B');
    expect(starts.last.agentName, 'Coworker B');
    binding.dispose();
  });
}
