// lib/voice/incoming/incoming_call_mapping.dart
//
// Pure mappings of the incoming-call flow, kept apart so the tests can pin
// them without a plugin or a room:
//
//  * a ringing [IncomingCall] → the callkit ring ([incomingCallkitParams]);
//  * a user-started call → the callkit "ongoing call" that holds the
//    phoneCall + microphone foreground service ([outgoingCallkitParams]);
//  * an accepted call → the arguments of `VoiceCallController.start`
//    ([voiceStartRequestFor]).
//
// Privacy: the ring screen of flutter_callkit_incoming is backed by a
// notification whose text is the `handle`. The contract keeps `reason` out of
// every notification, so the handle is a neutral line and the reason only
// travels to the voice worker, which speaks it when the call connects.

import 'package:flutter_callkit_incoming/entities/entities.dart';

import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// The host rings for 120 s (`expires_at = created_at + 120`). A phone clock
/// that runs behind the host's would otherwise ring for longer; the host's
/// `missed` echo stops it anyway, this caps it before.
const Duration kIncomingRingMax = Duration(seconds: 120);

/// A ring shorter than this is not worth showing.
const Duration kIncomingRingMin = Duration(seconds: 2);

/// The neutral second line of the ring screen and its notification.
const String kIncomingHandleNormal = 'Voice call';
const String kIncomingHandleUrgent = 'Urgent call';

/// The name an ongoing call shows for a normal chat. A chat title is content
/// (it often names the topic), so it stays out of the notification.
const String kOngoingChatCallName = 'Chuk Chat';

/// The callkit ring for [call] at [now], or null when the ring is already
/// over (or too short to show).
///
/// [startServiceOnAccept]: whether callkit starts its ongoing-call
/// foreground service by itself when Accept is pressed. Only when the
/// microphone is already granted: the service takes its microphone type at
/// start. Without it the service is started later, after the permission
/// ([outgoingCallkitParams] with the same id).
CallKitParams? incomingCallkitParams(
  IncomingCall call,
  DateTime now, {
  bool startServiceOnAccept = true,
}) {
  Duration ring = call.remainingAt(now);
  if (ring < kIncomingRingMin) return null;
  if (ring > kIncomingRingMax) ring = kIncomingRingMax;
  return CallKitParams(
    id: call.callId,
    nameCaller: call.agentName,
    appName: 'Chuk Chat',
    handle: call.isUrgent ? kIncomingHandleUrgent : kIncomingHandleNormal,
    type: 0,
    duration: ring.inMilliseconds,
    // Only a marker: the call itself lives in the Dart service.
    extra: const <String, dynamic>{'kind': 'agent_call'},
    missedCallNotification: const NotificationParams(
      showNotification: true,
      isShowCallback: false,
      subtitle: 'Missed call',
    ),
    callingNotification: startServiceOnAccept
        ? _callingNotification
        : const NotificationParams(showNotification: false),
    android: const AndroidParams(
      isCustomNotification: false,
      isShowLogo: false,
      // Shows the handle line on the full screen.
      isShowCallID: true,
      isShowFullLockedScreen: true,
      // The ring goes through the notification's full-screen intent, which
      // Android lets through from the background and over the lock screen. A
      // direct activity start (isFullScreen: true) is blocked from the
      // background unless the app may draw over other apps.
      isFullScreen: false,
      isImportant: true,
      backgroundColor: '#101418',
      actionColor: '#285DA9',
      textColor: '#FFFFFF',
      textAccept: 'Accept',
      textDecline: 'Decline',
      incomingCallNotificationChannelName: 'Incoming voice calls',
      missedCallNotificationChannelName: 'Missed voice calls',
    ),
  );
}

/// The callkit call for a call the user started: no ring, only the ongoing
/// call whose foreground service (phoneCall + microphone) keeps the
/// microphone open while the app is in the background.
CallKitParams outgoingCallkitParams({
  required String id,
  required String name,
}) => CallKitParams(
  id: id,
  nameCaller: name,
  appName: 'Chuk Chat',
  handle: kIncomingHandleNormal,
  type: 0,
  extra: const <String, dynamic>{'kind': 'user_call'},
  callingNotification: _callingNotification,
  android: const AndroidParams(isCustomNotification: false, isShowCallID: true),
);

const NotificationParams _callingNotification = NotificationParams(
  showNotification: true,
  isShowCallback: true,
  subtitle: 'Voice call',
  callbackText: 'Hang up',
);

/// What `VoiceCallController.start` gets for an accepted call.
class VoiceStartRequest {
  const VoiceStartRequest({
    required this.chatId,
    required this.mode,
    required this.agentName,
    required this.context,
    required this.callId,
    required this.callReason,
    required this.initiatedByAgent,
    this.chatTitle,
  });

  final String chatId;
  final VoiceCallMode mode;
  final String? chatTitle;
  final String agentName;
  final String context;
  final String callId;
  final String callReason;
  final bool initiatedByAgent;
}

/// The start of the voice session for an accepted [call]: its Agents thread,
/// the coworker's name, the call id and the reason, marked as started by the
/// agent so the worker speaks first (spec §6.3).
VoiceStartRequest voiceStartRequestFor(
  IncomingCall call, {
  String? chatTitle,
  String context = '',
}) => VoiceStartRequest(
  chatId: call.threadId,
  mode: VoiceCallMode.agents,
  chatTitle: chatTitle,
  agentName: call.agentName,
  context: context,
  callId: call.callId,
  callReason: call.reason,
  initiatedByAgent: true,
);
