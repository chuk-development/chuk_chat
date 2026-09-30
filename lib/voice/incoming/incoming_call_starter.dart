// lib/voice/incoming/incoming_call_starter.dart
//
// The two app hooks of the incoming-call service: open the chat a call
// belongs to, and start the voice session of an accepted agent call.

import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart'
    show startAgentsThreadVoiceCall;
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_mapping.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// How long an accepted call waits for its thread screen to open, so the
/// call gets the screen's task delegate (the same wait the coworker profile
/// uses).
const Duration kAcceptedCallThreadWait = Duration(seconds: 2);

/// Brings the chat of a call to the front: the Agents thread through the
/// notification router (the shell selects it and brings the Agents half
/// forward, the way a tapped "answer ready" toast does), a normal chat
/// through the shared chat pointer.
void openVoiceCallChat(String chatId, VoiceCallMode? mode) {
  if (chatId.isEmpty) return;
  if (mode == VoiceCallMode.agents || ChatOrigin.isAgentsThread(chatId)) {
    NotificationRouter.instance.open(NotificationTarget(sessionKey: chatId));
    return;
  }
  if (ChatStorageService.selectedChatId != chatId) {
    ChatStorageService.selectedChatId = chatId;
  }
}

/// Opens the thread of an accepted [call] and starts its voice session:
/// started by the agent, with the call id and the reason, so the worker
/// speaks first.
///
/// The start goes through the thread screen once it is open (within
/// [waitForThread]), so the call carries its `AgentsVoiceDelegate` and the
/// worker can hand work to the host. When the screen never shows up, the
/// call starts on the controller with the stored thread as its context and
/// no delegate. [enabled] is a test seam (default: voice calls are on).
Future<void> startAcceptedAgentCall(
  IncomingCall call, {
  VoiceCallController? controller,
  Duration waitForThread = kAcceptedCallThreadWait,
  bool? enabled,
}) async {
  openVoiceCallChat(call.threadId, VoiceCallMode.agents);
  final VoiceStartRequest request = voiceStartRequestFor(call);
  await startAgentsThreadVoiceCall(
    threadKey: request.chatId,
    agentName: request.agentName,
    waitForThread: waitForThread,
    controller: controller,
    callId: request.callId,
    callReason: request.callReason,
    initiatedByAgent: request.initiatedByAgent,
    enabled: enabled,
  );
}
