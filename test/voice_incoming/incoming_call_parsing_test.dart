// The frames of "the agent calls the user" (docs/WIRE_CONTRACT.md) and the
// book that dedupes them by call_id and drops expired rings.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_voice_call_frames.dart';
import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_book.dart';

import 'fakes.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 9, 30, 12);
  IncomingCall? parse(Map<String, dynamic> frame, {DateTime? at}) =>
      IncomingCall.fromFrame(frame, now: at ?? now);

  group('IncomingCall.fromFrame', () {
    test('reads the eight keys of the contract', () {
      final IncomingCall? call = parse(
        incomingFrame(
          urgency: 'high',
          expiresAt: now.add(const Duration(seconds: 90)),
        ),
      );
      expect(call, isNotNull);
      expect(call!.callId, '3f2a9c1d0b7e4a55');
      expect(call.threadId, 'local:crypto-desk:1:74112');
      expect(call.agentId, 'local:crypto-desk:1:74112');
      expect(call.agentName, 'Crypto Desk');
      expect(call.reason, 'Your pizza is ready to come out of the oven.');
      expect(call.isUrgent, isTrue);
      expect(call.expiresAt, now.add(const Duration(seconds: 90)));
      expect(call.remainingAt(now), const Duration(seconds: 90));
    });

    test('ignores unknown keys and takes fractional seconds', () {
      final Map<String, dynamic> frame = incomingFrame(expiresAt: now)
        ..['expires_at'] = 1790000120.5
        ..['something_new'] = 42;
      final IncomingCall call = parse(frame)!;
      expect(call.expiresAt.millisecondsSinceEpoch, 1790000120500);
    });

    test(
      'ring_seconds sets the end on this clock, whatever expires_at says',
      () {
        // The host clock runs ten minutes ahead: its expires_at is in our
        // future by far, and a phone behind it would ring for 12 minutes.
        final IncomingCall call = parse(
          incomingFrame(
            expiresAt: now.add(const Duration(minutes: 12)),
            ringSeconds: 90,
          ),
        )!;
        expect(call.expiresAt, now.add(const Duration(seconds: 90)));
        expect(call.remainingAt(now), const Duration(seconds: 90));
      },
    );

    test('ring_seconds alone is enough; a fractional one is kept', () {
      final Map<String, dynamic> frame = incomingFrame(
        expiresAt: now,
        ringSeconds: 45.5,
      )..remove('expires_at');
      expect(
        parse(frame)!.expiresAt,
        now.add(const Duration(milliseconds: 45500)),
      );
    });

    test('a bad ring_seconds falls back to expires_at', () {
      final DateTime end = now.add(const Duration(seconds: 70));
      for (final Object bad in <Object>[-1, double.nan, '90']) {
        final Map<String, dynamic> frame = incomingFrame(expiresAt: end)
          ..['ring_seconds'] = bad;
        expect(parse(frame)!.expiresAt, end, reason: '$bad');
      }
    });

    test('an unnamed coworker is "Your coworker"', () {
      final IncomingCall call = parse(
        incomingFrame(agentName: '  ', expiresAt: now),
      )!;
      expect(call.agentName, IncomingCall.defaultAgentName);
    });

    test('an unknown urgency reads as normal', () {
      final IncomingCall call = parse(
        incomingFrame(urgency: 'panic', expiresAt: now),
      )!;
      expect(call.urgency, IncomingCallUrgency.normal);
    });

    test('an over-long reason is cut with an ellipsis', () {
      final IncomingCall call = parse(
        incomingFrame(reason: 'x' * 1500, expiresAt: now),
      )!;
      expect(call.reason.length, IncomingCall.maxReasonChars);
      expect(call.reason.endsWith('…'), isTrue);
    });

    test('drops frames without call_id, thread_id or expires_at', () {
      for (final String key in <String>['call_id', 'thread_id', 'expires_at']) {
        final Map<String, dynamic> frame = incomingFrame(expiresAt: now)
          ..remove(key);
        expect(parse(frame), isNull, reason: key);
      }
      expect(parse(incomingFrame(callId: '', expiresAt: now)), isNull);
      expect(
        parse(<String, dynamic>{
          ...incomingFrame(expiresAt: now),
          'type': 'voice_call_state',
        }),
        isNull,
      );
    });
  });

  group('HostCallState.fromFrame', () {
    test('reads the four host states', () {
      for (final String s in <String>[
        'accepted',
        'declined',
        'missed',
        'ended',
      ]) {
        expect(HostCallState.fromFrame(stateFrame('c1', s))?.state, s);
      }
    });

    test('drops ringing, unknown states and missing ids', () {
      expect(HostCallState.fromFrame(stateFrame('c1', 'ringing')), isNull);
      expect(HostCallState.fromFrame(stateFrame('c1', 'weird')), isNull);
      expect(HostCallState.fromFrame(stateFrame('', 'ended')), isNull);
    });
  });

  group('AgentsVoiceCallFrames', () {
    test('the app frame carries exactly type, call_id and state', () {
      expect(
        AgentsVoiceCallFrames.stateFrame(callId: 'c1', state: 'accepted'),
        <String, dynamic>{
          'type': 'voice_call_state',
          'call_id': 'c1',
          'state': 'accepted',
        },
      );
    });

    test('the app never reports missed or ringing', () {
      expect(
        () => AgentsVoiceCallFrames.stateFrame(callId: 'c1', state: 'missed'),
        throwsArgumentError,
      );
      expect(
        () => AgentsVoiceCallFrames.stateFrame(callId: 'c1', state: 'ringing'),
        throwsArgumentError,
      );
    });

    test('deliver passes only the two voice-call types on', () async {
      final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
      final sub = AgentsVoiceCallFrames.instance.frames.listen(got.add);
      AgentsVoiceCallFrames.instance
        ..deliver(<String, dynamic>{'type': 'delta', 'text': 'hi'})
        ..deliver(stateFrame('c1', 'ended'))
        ..deliver(incomingFrame(expiresAt: now));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(got.map((Map<String, dynamic> f) => f['type']), <String>[
        'voice_call_state',
        'voice_call_incoming',
      ]);
    });
  });

  group('IncomingCallBook', () {
    IncomingCall callAt(Duration left, {String id = 'c1'}) =>
        parse(incomingFrame(callId: id, expiresAt: now.add(left)))!;

    test('rings a new call once; a re-sent frame is a no-op', () {
      final IncomingCallBook book = IncomingCallBook();
      final IncomingCall call = callAt(const Duration(seconds: 100));
      expect(book.admit(call, now), IncomingAdmission.ring);
      expect(book['c1']!.status, IncomingCallStatus.ringing);
      // Re-sent on reattach and on a token refresh: same call_id.
      expect(
        book.admit(call, now.add(const Duration(seconds: 5))),
        IncomingAdmission.duplicate,
      );
      expect(
        book.admit(call, now.add(const Duration(seconds: 9))),
        IncomingAdmission.duplicate,
      );
      expect(book.length, 1);
    });

    test('a finished call is still known, so its re-send does not ring', () {
      final IncomingCallBook book = IncomingCallBook();
      final IncomingCall call = callAt(const Duration(seconds: 100));
      book.admit(call, now);
      book['c1']!.status = IncomingCallStatus.declined;
      expect(
        book.admit(call, now.add(const Duration(seconds: 20))),
        IncomingAdmission.duplicate,
      );
    });

    test('an expired call never rings, and stays known', () {
      final IncomingCallBook book = IncomingCallBook();
      expect(
        book.admit(callAt(const Duration(seconds: -1)), now),
        IncomingAdmission.expired,
      );
      expect(book['c1']!.status, IncomingCallStatus.expired);
      expect(
        book.admit(callAt(const Duration(seconds: -1)), now),
        IncomingAdmission.duplicate,
      );
    });

    test('a ring with less than two seconds left is not shown', () {
      final IncomingCallBook book = IncomingCallBook();
      expect(
        book.admit(callAt(const Duration(milliseconds: 1500)), now),
        IncomingAdmission.expired,
      );
    });

    test('finished calls are forgotten well after their expiry', () {
      final IncomingCallBook book = IncomingCallBook(
        keepAfterExpiry: const Duration(minutes: 30),
      );
      book.admit(callAt(const Duration(seconds: 100)), now);
      book['c1']!.status = IncomingCallStatus.missed;
      book.admit(
        callAt(const Duration(seconds: 100), id: 'c2'),
        now.add(const Duration(minutes: 40)),
      );
      expect(book['c1'], isNull);
      expect(book['c2'], isNotNull);
    });

    test('a ringing call is never pruned', () {
      final IncomingCallBook book = IncomingCallBook(
        keepAfterExpiry: Duration.zero,
      );
      book.admit(callAt(const Duration(seconds: 100)), now);
      book.admit(
        callAt(const Duration(seconds: 100), id: 'c2'),
        now.add(const Duration(hours: 1)),
      );
      expect(book['c1']?.status, IncomingCallStatus.ringing);
    });

    test('holds at most maxEntries, dropping finished calls first', () {
      final IncomingCallBook book = IncomingCallBook(maxEntries: 2);
      book.admit(callAt(const Duration(seconds: 100), id: 'a'), now);
      book.admit(callAt(const Duration(seconds: 100), id: 'b'), now);
      book['b']!.status = IncomingCallStatus.ended;
      book.admit(callAt(const Duration(seconds: 100), id: 'c'), now);
      expect(book.length, 2);
      expect(book['a'], isNotNull);
      expect(book['b'], isNull);
      expect(book['c'], isNotNull);
    });
  });
}
