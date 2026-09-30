// An accepted agent call opens its thread and starts through the thread
// screen (with the task delegate); without a screen it falls back to a
// plain start. Either way: the call id, the reason and "started by the
// agent" reach VoiceCallController.start.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_turn_queue.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_starter.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

import 'fakes.dart';

const String _thread = 'local:crypto-desk:1:74112';
const String _reason = 'Your pizza is ready to come out of the oven.';

ChatVoiceBinding _binding(VoiceCallController controller) => ChatVoiceBinding(
  controller: controller,
  currentChatId: () => _thread,
  isAgentsScreen: true,
  messages: () => <Map<String, String>>[],
  isBusy: () => false,
  send: (String text, VoiceTurnStarted onStarted) async {},
  onRecordsChanged: () {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final IncomingCall call = IncomingCall.fromFrame(
    incomingFrame(
      threadId: _thread,
      reason: _reason,
      expiresAt: DateTime.now().add(const Duration(seconds: 100)),
    ),
    now: DateTime.now(),
  )!;
  late List<VoiceCallStartProbe> probes;

  setUp(() {
    ChatOrigin.agentsEnabled = true;
    probes = <VoiceCallStartProbe>[];
    debugOnVoiceCallStart = probes.add;
  });

  tearDown(() {
    debugOnVoiceCallStart = null;
    debugAgentsChatCoreOverride = null;
    NotificationRouter.instance.reset();
  });

  test(
    'opens the thread and starts through its screen, with the delegate',
    () async {
      final VoiceCallController controller = VoiceCallController.forTesting();
      final ChatVoiceBinding binding = _binding(controller);
      await startAcceptedAgentCall(call, controller: controller, enabled: true);

      expect(NotificationRouter.instance.pending.value?.sessionKey, _thread);
      final VoiceCallStartProbe p = probes.single;
      expect(p.hasDelegate, isTrue);
      expect(p.chatId, _thread);
      expect(p.mode, VoiceCallMode.agents);
      expect(p.agentName, 'Crypto Desk');
      expect(p.callId, '3f2a9c1d0b7e4a55');
      expect(p.callReason, _reason);
      expect(p.initiatedByAgent, isTrue);
      expect(controller.callId, '3f2a9c1d0b7e4a55');
      binding.dispose();
    },
  );

  test('waits for a thread screen that opens a moment later', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    ChatVoiceBinding? binding;
    Timer(
      const Duration(milliseconds: 150),
      () => binding = _binding(controller),
    );
    await startAcceptedAgentCall(
      call,
      controller: controller,
      waitForThread: const Duration(seconds: 2),
      enabled: true,
    );
    expect(probes.single.hasDelegate, isTrue);
    expect(probes.single.callId, '3f2a9c1d0b7e4a55');
    binding?.dispose();
  });

  test('falls back to a plain start when no screen shows up', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    await startAcceptedAgentCall(
      call,
      controller: controller,
      waitForThread: const Duration(milliseconds: 250),
      enabled: true,
    );
    final VoiceCallStartProbe p = probes.single;
    expect(p.hasDelegate, isFalse);
    expect(p.callId, '3f2a9c1d0b7e4a55');
    expect(p.callReason, _reason);
    expect(p.initiatedByAgent, isTrue);
    expect(controller.callId, '3f2a9c1d0b7e4a55');
  });
}
