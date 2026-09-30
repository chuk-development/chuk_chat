// The agent-call fields (spec §6.3) go through ChatVoiceBinding.startCall and
// startAgentsThreadVoiceCall to VoiceCallController.start, and an Agents
// thread that is open on its screen gives the call its task delegate.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_turn_queue.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

const String _thread = 'local:crypto-desk:1:74112';

ChatVoiceBinding _binding(VoiceCallController controller, String chatId) =>
    ChatVoiceBinding(
      controller: controller,
      currentChatId: () => chatId,
      isAgentsScreen: true,
      messages: () => <Map<String, String>>[
        <String, String>{'sender': 'user', 'text': 'hello'},
      ],
      isBusy: () => false,
      send: (String text, VoiceTurnStarted onStarted) async {},
      onRecordsChanged: () {},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<VoiceCallStartProbe> probes;

  setUp(() {
    ChatOrigin.agentsEnabled = true;
    probes = <VoiceCallStartProbe>[];
    debugOnVoiceCallStart = probes.add;
  });

  tearDown(() {
    debugOnVoiceCallStart = null;
    debugAgentsChatCoreOverride = null;
  });

  test(
    'startCall passes the agent-call fields on, with the delegate',
    () async {
      final VoiceCallController controller = VoiceCallController.forTesting();
      final ChatVoiceBinding binding = _binding(controller, _thread);
      await binding.startCall(
        agentName: 'Crypto Desk',
        callId: '3f2a9c1d0b7e4a55',
        callReason: 'The pizza is ready.',
        initiatedByAgent: true,
      );
      final VoiceCallStartProbe p = probes.single;
      expect(p.chatId, _thread);
      expect(p.mode, VoiceCallMode.agents);
      expect(p.agentName, 'Crypto Desk');
      expect(p.callId, '3f2a9c1d0b7e4a55');
      expect(p.callReason, 'The pizza is ready.');
      expect(p.initiatedByAgent, isTrue);
      expect(p.hasDelegate, isTrue);
      // The controller got it too (no token server in tests: it then fails).
      expect(controller.callId, '3f2a9c1d0b7e4a55');
      binding.dispose();
    },
  );

  test('a call the user starts keeps the old arguments', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    final ChatVoiceBinding binding = _binding(controller, _thread);
    await binding.startCall(agentName: 'Crypto Desk');
    final VoiceCallStartProbe p = probes.single;
    expect(p.callId, isNull);
    expect(p.callReason, isNull);
    expect(p.initiatedByAgent, isFalse);
    expect(p.hasDelegate, isTrue);
    expect(controller.callId, isNull);
    binding.dispose();
  });

  test(
    'startAgentsThreadVoiceCall goes through the open thread screen',
    () async {
      final VoiceCallController controller = VoiceCallController.forTesting();
      final ChatVoiceBinding binding = _binding(controller, _thread);
      await startAgentsThreadVoiceCall(
        threadKey: _thread,
        agentName: 'Crypto Desk',
        callId: 'c1',
        callReason: 'why',
        initiatedByAgent: true,
        enabled: true,
      );
      final VoiceCallStartProbe p = probes.single;
      expect(p.hasDelegate, isTrue);
      expect(p.callId, 'c1');
      expect(p.callReason, 'why');
      expect(p.initiatedByAgent, isTrue);
      expect(controller.callId, 'c1');
      binding.dispose();
    },
  );

  test('without the thread screen it starts plainly, fields intact', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    await startAgentsThreadVoiceCall(
      threadKey: _thread,
      agentName: 'Crypto Desk',
      controller: controller,
      callId: 'c2',
      callReason: 'why',
      initiatedByAgent: true,
      enabled: true,
    );
    final VoiceCallStartProbe p = probes.single;
    expect(p.hasDelegate, isFalse);
    expect(p.mode, VoiceCallMode.agents);
    expect(p.callId, 'c2');
    expect(p.callReason, 'why');
    expect(p.initiatedByAgent, isTrue);
    expect(controller.callId, 'c2');
  });

  test('with voice calls off nothing starts', () async {
    final VoiceCallController controller = VoiceCallController.forTesting();
    await startAgentsThreadVoiceCall(
      threadKey: _thread,
      controller: controller,
      callId: 'c3',
      initiatedByAgent: true,
    );
    expect(probes, isEmpty);
    expect(controller.phase, VoiceCallPhase.idle);
  });
}
