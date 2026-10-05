import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_turn_queue.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// A fake chat screen: a new chat (no id) until [ensureChatId] gives it one.
class _Screen {
  String? chatId;
  final List<Map<String, String>> messages = <Map<String, String>>[];
  final List<String> discarded = <String>[];
  int creates = 0;

  /// When set, a creation waits for it (a slow first save).
  Completer<void>? gate;

  Future<String?> ensureChatId() async {
    creates++;
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    chatId = 'new-chat';
    return chatId;
  }

  Future<void> discardChat(String id) async {
    discarded.add(id);
    if (chatId == id) chatId = null;
  }
}

/// No LiveKit: the test build has no token server, so a started call fails
/// at once and shows its failed panel until it is dismissed.
ChatVoiceBinding _binding(
  VoiceCallController controller,
  _Screen screen, {
  bool onDemand = true,
}) => ChatVoiceBinding(
  controller: controller,
  currentChatId: () => screen.chatId,
  isAgentsScreen: false,
  isOffline: () => false,
  messages: () => screen.messages,
  isBusy: () => false,
  send: (String text, VoiceTurnStarted onStarted) async {},
  onRecordsChanged: () {},
  ensureChatId: onDemand ? screen.ensureChatId : null,
  discardChat: onDemand ? screen.discardChat : null,
);

/// Hangs up the failed call (its panel goes away) and lets the binding
/// settle the chat it made.
Future<void> _hangUp(VoiceCallController controller) async {
  controller.dismiss();
  await pumpEventQueue();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<VoiceCallStartProbe> starts;
  setUp(() {
    starts = <VoiceCallStartProbe>[];
    debugOnVoiceCallStart = starts.add;
  });
  tearDown(() => debugOnVoiceCallStart = null);

  test(
    'a call from a new chat makes the chat once and calls into it',
    () async {
      final VoiceCallController controller = VoiceCallController.forTesting();
      final _Screen screen = _Screen();
      final ChatVoiceBinding binding = _binding(controller, screen);
      addTearDown(binding.dispose);

      await binding.toggleCall();

      expect(screen.creates, 1);
      expect(starts, hasLength(1));
      expect(starts.single.chatId, 'new-chat');
      expect(starts.single.mode, VoiceCallMode.chat);
      expect(controller.chatId, 'new-chat');
    },
  );

  test('a double tap while the chat is made starts one call', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final _Screen screen = _Screen()..gate = Completer<void>();
    final ChatVoiceBinding binding = _binding(controller, screen);
    addTearDown(binding.dispose);

    final Future<void> first = binding.toggleCall();
    final Future<void> second = binding.toggleCall();
    screen.gate!.complete();
    await Future.wait(<Future<void>>[first, second]);

    expect(screen.creates, 1);
    expect(starts, hasLength(1));
    expect(starts.single.chatId, 'new-chat');
  });

  test('the empty chat a call made is given back after the hang-up', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final _Screen screen = _Screen();
    final ChatVoiceBinding binding = _binding(controller, screen);
    addTearDown(binding.dispose);

    await binding.toggleCall();
    await pumpEventQueue();
    // The panel (here: the failed one) is still up, so the chat stays.
    expect(binding.showsPanelFor('new-chat'), isTrue);
    expect(screen.discarded, isEmpty);

    await _hangUp(controller);
    expect(screen.discarded, <String>['new-chat']);
    expect(screen.chatId, isNull);
  });

  test('a chat that got a message during the call stays', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final _Screen screen = _Screen();
    final ChatVoiceBinding binding = _binding(controller, screen);
    addTearDown(binding.dispose);

    await binding.toggleCall();
    screen.messages.add(<String, String>{'sender': 'user', 'text': 'hi'});

    await _hangUp(controller);
    expect(screen.discarded, isEmpty);
    expect(screen.chatId, 'new-chat');
  });

  test('a chat that already had an id is never given back', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final _Screen screen = _Screen()..chatId = 'chat-a';
    final ChatVoiceBinding binding = _binding(controller, screen);
    addTearDown(binding.dispose);

    await binding.toggleCall();
    expect(screen.creates, 0);
    expect(starts.single.chatId, 'chat-a');

    await _hangUp(controller);
    expect(screen.discarded, isEmpty);
    expect(screen.chatId, 'chat-a');
  });

  test('without a chat creator a new chat cannot call', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final _Screen screen = _Screen();
    final ChatVoiceBinding binding = _binding(
      controller,
      screen,
      onDemand: false,
    );
    addTearDown(binding.dispose);

    await binding.toggleCall();
    expect(starts, isEmpty);
    expect(controller.chatId, isNull);
  });
}
