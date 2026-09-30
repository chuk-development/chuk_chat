// lib/voice/incoming/callkit_port.dart
//
// [CallkitPort] over flutter_callkit_incoming (Android). The plugin's event
// channel carries one listener at a time, so the events are read once here
// and shared.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';

class FlutterCallkitPort implements CallkitPort {
  FlutterCallkitPort();

  late final Stream<CallkitSignal> _signals = FlutterCallkitIncoming.onEvent
      .handleError((Object e) {
        // A malformed plugin event is dropped, never fatal.
        if (kDebugMode) debugPrint('[callkit] bad event: ${e.runtimeType}');
      })
      .map(signalFor)
      .where((CallkitSignal? s) => s != null)
      .cast<CallkitSignal>()
      .asBroadcastStream();

  @override
  Stream<CallkitSignal> get signals => _signals;

  /// The signal an event maps to, or null for the events the service does
  /// not act on (incoming, start, connected, iOS toggles).
  @visibleForTesting
  static CallkitSignal? signalFor(CallEvent? event) => switch (event) {
    CallEventActionCallAccept(:final CallKitParams callKitParams) =>
      CallkitSignal(CallkitSignalKind.accept, callKitParams.id),
    CallEventActionCallDecline(:final CallKitParams callKitParams) =>
      CallkitSignal(CallkitSignalKind.decline, callKitParams.id),
    CallEventActionCallEnded(:final CallKitParams callKitParams) =>
      CallkitSignal(CallkitSignalKind.ended, callKitParams.id),
    CallEventActionCallTimeout(:final String id) => CallkitSignal(
      CallkitSignalKind.timeout,
      id,
    ),
    _ => null,
  };

  @override
  Future<void> showIncoming(CallKitParams params) =>
      FlutterCallkitIncoming.showCallkitIncoming(params);

  @override
  Future<void> showMissed(CallKitParams params) =>
      FlutterCallkitIncoming.showMissCallNotification(params);

  @override
  Future<void> startOutgoing(CallKitParams params) =>
      FlutterCallkitIncoming.startCall(params);

  @override
  Future<void> setConnected(String id) =>
      FlutterCallkitIncoming.setCallConnected(id);

  @override
  Future<void> end(String id) => FlutterCallkitIncoming.endCall(id);
}
