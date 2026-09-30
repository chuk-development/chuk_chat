// lib/voice/incoming/ongoing_call_notification.dart
//
// [OngoingCallUi] over the platform channel of MainActivity
// (android/app/src/main/kotlin/dev/chuk/chat/voice/VoiceCallBridge.kt):
//
//  * `showOngoingCall` / `cancelOngoingCall` — the ongoing-call notification
//    with Hang up, Mute/Unmute, Speaker on/off, Volume up and Volume down. It
//    is posted under the notification id of callkit's own ongoing call, so it
//    replaces that one and keeps its foreground service; there is one
//    notification per call.
//  * `requestUnlock` — after a call is accepted on the lock screen, ask the
//    user to unlock. The app never shows over the lock screen itself.
//  * `showNotice` — a short toast (the microphone notice).
//  * the `chuk/voice_call_actions` event channel — the buttons that need the
//    Dart side (hang up, mute, speaker) and a tap on the notification (open).
//    Volume up/down never reach Dart: the native receiver moves
//    STREAM_VOICE_CALL itself.
//
// Android only; elsewhere every call is a no-op.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';

class OngoingCallNotification implements OngoingCallUi {
  OngoingCallNotification({
    this.channel = const MethodChannel(channelName),
    this.events = const EventChannel(eventChannelName),
  });

  static const String channelName = 'chuk/voice_call';
  static const String eventChannelName = 'chuk/voice_call_actions';

  final MethodChannel channel;
  final EventChannel events;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  late final Stream<OngoingCallAction> _actions = _android
      ? events
            .receiveBroadcastStream()
            .map(actionFor)
            .where((OngoingCallAction? a) => a != null)
            .cast<OngoingCallAction>()
            .asBroadcastStream()
      : const Stream<OngoingCallAction>.empty();

  @override
  Stream<OngoingCallAction> get actions => _actions;

  /// The action a native event names, or null.
  @visibleForTesting
  static OngoingCallAction? actionFor(Object? event) => switch (event) {
    'hangup' => OngoingCallAction.hangUp,
    'mute' => OngoingCallAction.toggleMute,
    'speaker' => OngoingCallAction.toggleSpeaker,
    'open' => OngoingCallAction.open,
    _ => null,
  };

  /// The channel arguments of [snapshot].
  @visibleForTesting
  static Map<String, Object?> argumentsFor(OngoingCallSnapshot snapshot) =>
      <String, Object?>{
        'callKey': snapshot.callKey,
        'title': snapshot.title,
        'status': snapshot.status,
        'muted': snapshot.muted,
        'speakerOn': snapshot.speakerOn,
        'canSwitchSpeaker': snapshot.canSwitchSpeaker,
        'connectedAtMs': snapshot.connectedAt?.millisecondsSinceEpoch ?? 0,
      };

  @override
  Future<void> show(OngoingCallSnapshot snapshot) async {
    if (!_android) return;
    await channel.invokeMethod<void>('showOngoingCall', argumentsFor(snapshot));
  }

  @override
  Future<void> cancel(String callKey) async {
    if (!_android) return;
    await channel.invokeMethod<void>('cancelOngoingCall', <String, Object?>{
      'callKey': callKey,
    });
  }

  @override
  Future<void> requestUnlock() async {
    if (!_android) return;
    await channel.invokeMethod<void>('requestUnlock');
  }

  @override
  Future<void> notice(String text) async {
    if (!_android) return;
    await channel.invokeMethod<void>('showNotice', <String, Object?>{
      'text': text,
    });
  }
}
