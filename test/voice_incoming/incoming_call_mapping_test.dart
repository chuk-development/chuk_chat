// frame → CallKitParams, accept → VoiceCallController.start arguments, and
// the small channel/event mappings of the platform side.

import 'dart:convert';

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/incoming/callkit_port.dart';
import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_mapping.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';
import 'package:chuk_chat/voice/incoming/ongoing_call_notification.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

import 'fakes.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 9, 30, 12);
  const String reason = 'Your pizza is ready to come out of the oven.';

  IncomingCall callWith({
    Duration left = const Duration(seconds: 90),
    String urgency = 'normal',
  }) => IncomingCall.fromFrame(
    incomingFrame(urgency: urgency, reason: reason, expiresAt: now.add(left)),
    now: now,
  )!;

  group('incomingCallkitParams', () {
    test('rings with the call id, the coworker name and the time left', () {
      final CallKitParams p = incomingCallkitParams(callWith(), now)!;
      expect(p.id, '3f2a9c1d0b7e4a55');
      expect(p.nameCaller, 'Crypto Desk');
      expect(p.type, 0);
      expect(p.duration, 90000);
      expect(p.handle, kIncomingHandleNormal);
    });

    test('an urgent call says so on the second line', () {
      final CallKitParams p = incomingCallkitParams(
        callWith(urgency: 'high'),
        now,
      )!;
      expect(p.handle, kIncomingHandleUrgent);
    });

    test('the ring is capped at 120 s', () {
      final CallKitParams p = incomingCallkitParams(
        callWith(left: const Duration(minutes: 10)),
        now,
      )!;
      expect(p.duration, kIncomingRingMax.inMilliseconds);
    });

    test('an expired call maps to nothing', () {
      expect(
        incomingCallkitParams(callWith(left: const Duration(seconds: -3)), now),
        isNull,
      );
    });

    test('shows over the lock screen through the full-screen intent', () {
      final AndroidParams android = incomingCallkitParams(
        callWith(),
        now,
      )!.android!;
      expect(android.isShowFullLockedScreen, isTrue);
      // Not a direct activity start: that is blocked from the background.
      expect(android.isFullScreen, isFalse);
      expect(android.isCustomNotification, isFalse);
    });

    test(
      'rings with a missed-call notice and an ongoing-call notification',
      () {
        final CallKitParams p = incomingCallkitParams(callWith(), now)!;
        expect(p.missedCallNotification?.showNotification, isTrue);
        expect(p.missedCallNotification?.isShowCallback, isFalse);
        expect(p.callingNotification?.showNotification, isTrue);
      },
    );

    test('without the microphone, Accept starts no callkit service', () {
      final CallKitParams p = incomingCallkitParams(
        callWith(),
        now,
        startServiceOnAccept: false,
      )!;
      expect(p.callingNotification?.showNotification, isFalse);
      // It still rings like any other call.
      expect(p.android?.isShowFullLockedScreen, isTrue);
      expect(p.duration, 90000);
    });

    test('the reason is nowhere in what the plugin (and its notification) '
        'gets', () {
      final CallKitParams p = incomingCallkitParams(callWith(), now)!;
      final String json = jsonEncode(p.toJson());
      expect(json.contains('pizza'), isFalse);
      expect(json.contains(reason), isFalse);
    });
  });

  test('outgoingCallkitParams: an ongoing call with no ring', () {
    final CallKitParams p = outgoingCallkitParams(
      id: 'k1',
      name: 'Crypto Desk',
    );
    expect(p.id, 'k1');
    expect(p.nameCaller, 'Crypto Desk');
    expect(p.type, 0);
    expect(p.callingNotification?.showNotification, isTrue);
    expect(p.missedCallNotification, isNull);
  });

  test('voiceStartRequestFor: the accepted call starts in its thread, '
      'started by the agent, with id and reason', () {
    final VoiceStartRequest r = voiceStartRequestFor(
      callWith(),
      chatTitle: 'Crypto Desk',
      context: 'User: hi',
    );
    expect(r.chatId, 'local:crypto-desk:1:74112');
    expect(r.mode, VoiceCallMode.agents);
    expect(r.agentName, 'Crypto Desk');
    expect(r.chatTitle, 'Crypto Desk');
    expect(r.context, 'User: hi');
    expect(r.callId, '3f2a9c1d0b7e4a55');
    expect(r.callReason, reason);
    expect(r.initiatedByAgent, isTrue);
  });

  group('FlutterCallkitPort.signalFor', () {
    const CallKitParams params = CallKitParams(id: 'c1');

    test('maps the four events the service acts on', () {
      expect(
        FlutterCallkitPort.signalFor(const CallEventActionCallAccept(params)),
        const CallkitSignal(CallkitSignalKind.accept, 'c1'),
      );
      expect(
        FlutterCallkitPort.signalFor(const CallEventActionCallDecline(params)),
        const CallkitSignal(CallkitSignalKind.decline, 'c1'),
      );
      expect(
        FlutterCallkitPort.signalFor(const CallEventActionCallEnded(params)),
        const CallkitSignal(CallkitSignalKind.ended, 'c1'),
      );
      expect(
        FlutterCallkitPort.signalFor(const CallEventActionCallTimeout('c1')),
        const CallkitSignal(CallkitSignalKind.timeout, 'c1'),
      );
    });

    test('ignores the rest', () {
      expect(
        FlutterCallkitPort.signalFor(const CallEventActionCallIncoming(params)),
        isNull,
      );
      expect(
        FlutterCallkitPort.signalFor(const CallEventActionCallConnected('c1')),
        isNull,
      );
      expect(FlutterCallkitPort.signalFor(null), isNull);
    });
  });

  group('OngoingCallNotification', () {
    test('button events map to actions; volume never reaches Dart', () {
      expect(
        OngoingCallNotification.actionFor('hangup'),
        OngoingCallAction.hangUp,
      );
      expect(
        OngoingCallNotification.actionFor('mute'),
        OngoingCallAction.toggleMute,
      );
      expect(
        OngoingCallNotification.actionFor('speaker'),
        OngoingCallAction.toggleSpeaker,
      );
      expect(OngoingCallNotification.actionFor('open'), OngoingCallAction.open);
      expect(OngoingCallNotification.actionFor('volume_up'), isNull);
    });

    test('the channel arguments of a snapshot', () {
      final DateTime at = DateTime.utc(2026, 9, 30, 12, 0, 5);
      expect(
        OngoingCallNotification.argumentsFor(
          OngoingCallSnapshot(
            callKey: 'c1',
            title: 'Crypto Desk',
            status: 'On call',
            muted: true,
            speakerOn: false,
            canSwitchSpeaker: true,
            connectedAt: at,
          ),
        ),
        <String, Object?>{
          'callKey': 'c1',
          'title': 'Crypto Desk',
          'status': 'On call',
          'muted': true,
          'speakerOn': false,
          'canSwitchSpeaker': true,
          'connectedAtMs': at.millisecondsSinceEpoch,
        },
      );
    });
  });
}
