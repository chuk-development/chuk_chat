// lib/voice/voice_call.dart
//
// The voice-call core in one import (FEATURE_VOICE_CALL, owner-only test,
// docs/PERSONAL_AGENT_SPEC.md §6.1):
//
//   import 'package:chuk_chat/voice/voice_call.dart';
//
//   if (VoiceCallService.isAvailable) VoiceCallButton(onPressed: ...)
//   VoiceCallController.instance.start(chatId: ..., mode: VoiceCallMode.chat)
//   VoiceCallPanel(chatId: ...)            // above the composer
//   VoiceCallController.instance.onCallEnded.listen(...)  // record -> chat
//   VoiceCallStore.forChat(chatId)         // records after a restart
//   VoiceCallRecordCard(record)            // in the chat history

export 'voice_call_controller.dart' show VoiceCallController;
export 'voice_call_models.dart';
export 'voice_call_service.dart' show VoiceCallService, VoiceCallException;
export 'voice_call_store.dart' show VoiceCallStore;
export 'widgets/voice_call_button.dart' show VoiceCallButton;
export 'widgets/voice_call_panel.dart'
    show VoiceCallPanel, VoiceTurnLine, formatVoiceCallClock;
export 'widgets/voice_agent_card.dart' show VoiceAgentCard;
export 'widgets/voice_call_record_card.dart'
    show VoiceCallRecordCard, describeVoiceCall, voiceCallTimeline;
