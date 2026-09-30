// lib/voice/incoming/incoming_call_bootstrap.dart
//
// The one entry point of lib/voice/incoming/: `main()` calls
// [IncomingCallBootstrap.start] once. With `FEATURE_VOICE_CALL` off (or no
// token server, or not Android) it returns at once: no listener, no plugin
// call, no permission prompt.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/agents/agents_voice_call_frames.dart';
import 'package:chuk_chat/voice/incoming/callkit_port.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_service.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_starter.dart';
import 'package:chuk_chat/voice/incoming/ongoing_call_notification.dart';
import 'package:chuk_chat/voice/incoming/relay_call_state_sender.dart';
import 'package:chuk_chat/voice/incoming/voice_call_permissions.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_service.dart';

/// Whether this build takes agent calls and shows the ongoing-call
/// notification: the voice-call flag, a token server, and Android (the ring
/// screen and the call foreground service are Android's).
bool get voiceIncomingEnabled =>
    kFeatureVoiceCall &&
    VoiceCallService.isAvailable &&
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android;

abstract final class IncomingCallBootstrap {
  static IncomingCallService? _service;

  /// The running service, or null (flag off, not started).
  static IncomingCallService? get service => _service;

  /// How long after the first frame the permission questions come, so they
  /// do not fight the app's own start-up prompts.
  static const Duration _permissionDelay = Duration(seconds: 3);

  /// Starts the service once. Needs `WidgetsFlutterBinding` (main() has it).
  static void start() {
    if (!voiceIncomingEnabled || _service != null) return;
    final IncomingCallService service = IncomingCallService(
      hostFrames: AgentsVoiceCallFrames.instance.frames,
      callkit: FlutterCallkitPort(),
      sender: RelayCallStateSender(),
      ui: OngoingCallNotification(),
      call: ControllerVoiceCallView(VoiceCallController.instance),
      starter: startAcceptedAgentCall,
      openChat: openVoiceCallChat,
      mic: const PermissionHandlerMic(),
    );
    _service = service;
    service.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        Future<void>.delayed(
          _permissionDelay,
          VoiceCallPermissions.requestUpFront,
        ),
      );
    });
    if (kDebugMode) debugPrint('[incoming-call] listening');
  }
}
