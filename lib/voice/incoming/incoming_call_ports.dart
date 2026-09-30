// lib/voice/incoming/incoming_call_ports.dart
//
// The seams of the incoming-call service. The service only talks to these;
// the real ones wrap flutter_callkit_incoming, the relay link, the platform
// channel of MainActivity and the app-wide VoiceCallController. The tests
// hand in fakes.

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';

import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// What the callkit UI reports.
enum CallkitSignalKind { accept, decline, ended, timeout }

@immutable
class CallkitSignal {
  const CallkitSignal(this.kind, this.id);

  final CallkitSignalKind kind;

  /// The callkit id: the host's `call_id` for an agent call, the service's own
  /// id for a call the user started.
  final String id;

  @override
  bool operator ==(Object other) =>
      other is CallkitSignal && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'CallkitSignal(${kind.name}, $id)';
}

/// The ring screen and the self-managed "ongoing call" of the OS.
abstract interface class CallkitPort {
  Stream<CallkitSignal> get signals;

  /// Rings: the full screen over the lock screen, or a heads-up call.
  Future<void> showIncoming(CallKitParams params);

  /// The "missed call" notice (name only, never the reason).
  Future<void> showMissed(CallKitParams params);

  /// An ongoing call with no ring (a call the user started). Starts the
  /// phoneCall + microphone foreground service.
  Future<void> startOutgoing(CallKitParams params);

  /// The call is connected (the agent can listen).
  Future<void> setConnected(String id);

  /// Stops the ring, or ends the ongoing call and its foreground service.
  Future<void> end(String id);
}

/// Sends `voice_call_state` to the host. Never throws: a frame that cannot go
/// out now is kept and sent once the host is attached again.
abstract interface class CallStateSender {
  Future<void> send(String callId, String state);
}

/// A button on the ongoing-call notification that needs the Dart side.
/// (Volume up/down are handled natively: they only move the call stream.)
enum OngoingCallAction { hangUp, toggleMute, toggleSpeaker, open }

/// What the ongoing-call notification shows.
@immutable
class OngoingCallSnapshot {
  const OngoingCallSnapshot({
    required this.callKey,
    required this.title,
    required this.status,
    required this.muted,
    required this.speakerOn,
    required this.canSwitchSpeaker,
    this.connectedAt,
  });

  /// The callkit id. The notification takes its place (same notification id),
  /// so there is one ongoing-call notification, not two.
  final String callKey;
  final String title;

  /// "Connecting…", "On call", "Muted".
  final String status;
  final bool muted;
  final bool speakerOn;
  final bool canSwitchSpeaker;

  /// When the agent joined; the notification counts up from here.
  final DateTime? connectedAt;

  @override
  bool operator ==(Object other) =>
      other is OngoingCallSnapshot &&
      other.callKey == callKey &&
      other.title == title &&
      other.status == status &&
      other.muted == muted &&
      other.speakerOn == speakerOn &&
      other.canSwitchSpeaker == canSwitchSpeaker &&
      other.connectedAt == connectedAt;

  @override
  int get hashCode => Object.hash(
    callKey,
    title,
    status,
    muted,
    speakerOn,
    canSwitchSpeaker,
    connectedAt,
  );
}

/// The ongoing-call notification with its buttons, and the two small native
/// helpers around an accepted call. The app itself never shows over the lock
/// screen: the ring there is callkit's own screen, and an accepted call runs
/// its audio in the callkit foreground service until the user unlocks.
abstract interface class OngoingCallUi {
  Stream<OngoingCallAction> get actions;
  Future<void> show(OngoingCallSnapshot snapshot);
  Future<void> cancel(String callKey);

  /// Asks the user to unlock (`KeyguardManager.requestDismissKeyguard`). Does
  /// nothing when the phone is not locked.
  Future<void> requestUnlock();

  /// A short system notice (a toast). Never content.
  Future<void> notice(String text);
}

/// The microphone permission. A call accepted without it would run the
/// foreground service without its microphone type, and the agent would hear
/// nothing once the app is in the background.
abstract interface class MicPermission {
  Future<bool> isGranted();

  /// Asks for it. True when granted; false when refused (or refused for
  /// good).
  Future<bool> request();
}

/// Opens the chat a call belongs to (the Agents thread for an agent call).
typedef CallChatOpener = void Function(String chatId, VoiceCallMode? mode);

/// Opens the thread of an accepted [call] and starts its voice session.
typedef IncomingCallStarter = Future<void> Function(IncomingCall call);

/// The part of the app-wide call the service reads and drives.
abstract interface class VoiceCallView implements Listenable {
  VoiceCallPhase get phase;
  bool get isActive;
  String? get callId;
  String? get chatId;
  VoiceCallMode? get mode;
  String? get agentName;
  bool get agentPresent;
  bool get micMuted;
  bool get speakerOn;
  bool get canSwitchSpeaker;
  DateTime? get startedAt;

  Future<void> end();
  Future<void> setMicMuted(bool muted);
  Future<void> setSpeakerOn(bool on);
}

/// [VoiceCallView] over the real controller.
class ControllerVoiceCallView implements VoiceCallView {
  ControllerVoiceCallView(this.controller);

  final VoiceCallController controller;

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  VoiceCallPhase get phase => controller.phase;
  @override
  bool get isActive => controller.isActive;
  @override
  String? get callId => controller.callId;
  @override
  String? get chatId => controller.chatId;
  @override
  VoiceCallMode? get mode => controller.mode;
  @override
  String? get agentName => controller.agentName;
  @override
  bool get agentPresent => controller.agentPresent;
  @override
  bool get micMuted => controller.micMuted;
  @override
  bool get speakerOn => controller.speakerOn;
  @override
  bool get canSwitchSpeaker => controller.canSwitchSpeaker;
  @override
  DateTime? get startedAt => controller.startedAt;

  @override
  Future<void> end() async {
    await controller.end();
  }

  @override
  Future<void> setMicMuted(bool muted) => controller.setMicMuted(muted);

  @override
  Future<void> setSpeakerOn(bool on) => controller.setSpeakerOn(on);
}
