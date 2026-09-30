// The incoming-call service with fakes: the ring, accept / decline /
// timeout, the host's echo, and the ongoing call of agent-started and
// user-started calls. The state frames sent are the contract's
// (docs/WIRE_CONTRACT.md, "The agent calls the user").

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/incoming/incoming_call_book.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_mapping.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_service.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

import 'fakes.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 9, 30, 12);
  const String id = '3f2a9c1d0b7e4a55';
  const String thread = 'local:crypto-desk:1:74112';

  late StreamController<Map<String, dynamic>> frames;
  late FakeCallkit callkit;
  late FakeSender sender;
  late FakeUi ui;
  late FakeCall call;
  late FakeStarter starter;
  late List<(String, VoiceCallMode?)> opened;
  late FakeMic mic;
  late IncomingCallService service;

  setUp(() {
    frames = StreamController<Map<String, dynamic>>.broadcast(sync: true);
    callkit = FakeCallkit();
    sender = FakeSender();
    ui = FakeUi();
    call = FakeCall();
    starter = FakeStarter(call);
    opened = <(String, VoiceCallMode?)>[];
    mic = FakeMic();
    service = IncomingCallService(
      hostFrames: frames.stream,
      callkit: callkit,
      sender: sender,
      ui: ui,
      call: call,
      starter: starter.start,
      openChat: (String chatId, VoiceCallMode? mode) =>
          opened.add((chatId, mode)),
      mic: mic,
      now: () => now,
      newCallKey: () => 'user-call-1',
      repostDelays: const <Duration>[],
    )..start();
  });

  tearDown(() async {
    await service.dispose();
    await frames.close();
  });

  Future<void> settle() => pumpEventQueue();

  Future<void> ring({Duration left = const Duration(seconds: 100)}) async {
    frames.add(incomingFrame(callId: id, expiresAt: now.add(left)));
    await settle();
  }

  group('ringing', () {
    test('a frame rings once; the re-sent frame is a no-op', () async {
      await ring();
      await ring();
      frames.add(
        incomingFrame(
          callId: id,
          expiresAt: now.add(const Duration(seconds: 100)),
        ),
      );
      await settle();
      expect(callkit.shown, hasLength(1));
      expect(callkit.shown.single.id, id);
      expect(callkit.shown.single.nameCaller, 'Crypto Desk');
      expect(sender.sent, isEmpty);
    });

    test('an expired frame never rings', () async {
      await ring(left: const Duration(seconds: -5));
      expect(callkit.shown, isEmpty);
      expect(service.book[id]!.status, IncomingCallStatus.expired);
    });

    test('a malformed frame is ignored', () async {
      frames.add(<String, dynamic>{'type': 'voice_call_incoming'});
      await settle();
      expect(callkit.shown, isEmpty);
    });
  });

  group('answering', () {
    test('accept: accepted, the thread opens and the call starts as the '
        "agent's", () async {
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();

      expect(sender.sent, <(String, String)>[(id, 'accepted')]);
      expect(starter.started, hasLength(1));
      expect(starter.started.single.callId, id);
      expect(starter.started.single.threadId, thread);
      // Never over the lock screen: the user is asked to unlock instead.
      expect(ui.unlocks, 1);
      expect(mic.requests, 0);
      expect(callkit.started, isEmpty);
      expect(service.sessionKey, id);
      expect(service.book[id]!.status, IncomingCallStatus.accepted);
    });

    test('decline: declined, nothing starts', () async {
      await ring();
      callkit.emit(CallkitSignalKind.decline, id);
      await settle();
      expect(sender.sent, <(String, String)>[(id, 'declined')]);
      expect(starter.started, isEmpty);
    });

    test(
      'the local ring running out sends nothing: missed is the host\'s',
      () async {
        await ring();
        callkit.emit(CallkitSignalKind.timeout, id);
        await settle();
        expect(sender.sent, isEmpty);
        expect(service.book[id]!.status, IncomingCallStatus.missed);
        // A late decline for the same call changes nothing.
        callkit.emit(CallkitSignalKind.decline, id);
        await settle();
        expect(sender.sent, isEmpty);
      },
    );

    test('accept of a ring this run does not know only ends it', () async {
      callkit.emit(CallkitSignalKind.accept, 'stale');
      await settle();
      expect(callkit.ended, <String>['stale']);
      expect(sender.sent, isEmpty);
      expect(starter.started, isEmpty);
    });

    test('a second accept for the same call is ignored', () async {
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      expect(starter.started, hasLength(1));
      expect(sender.sent, <(String, String)>[(id, 'accepted')]);
    });
  });

  group('the accepted call', () {
    Future<void> acceptAndConnect() async {
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      call.goLive();
      await settle();
    }

    test(
      'connected once the agent is in the room; our notification shows',
      () async {
        await ring();
        callkit.emit(CallkitSignalKind.accept, id);
        await settle();
        expect(callkit.connected, isEmpty);
        expect(ui.shown.last.status, 'Connecting…');

        call.goLive(agent: false);
        await settle();
        expect(callkit.connected, isEmpty);

        call.goLive();
        await settle();
        expect(callkit.connected, <String>[id]);
        final OngoingCallSnapshot shown = ui.shown.last;
        expect(shown.callKey, id);
        expect(shown.title, 'Crypto Desk');
        expect(shown.status, 'On call');
        expect(shown.connectedAt, now);
      },
    );

    test(
      'hanging up: ended, the callkit call ends, the notification goes',
      () async {
        await acceptAndConnect();
        call.finish();
        await settle();
        expect(sender.sent, <(String, String)>[
          (id, 'accepted'),
          (id, 'ended'),
        ]);
        expect(callkit.ended, <String>[id]);
        expect(ui.cancelled, <String>[id]);
        expect(service.sessionKey, isNull);
        expect(service.book[id]!.status, IncomingCallStatus.ended);
      },
    );

    test('a call that fails to connect also sends ended', () async {
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      call.finish(VoiceCallPhase.failed);
      await settle();
      expect(sender.sent, <(String, String)>[(id, 'accepted'), (id, 'ended')]);
      expect(callkit.ended, <String>[id]);
    });

    test('the OS ending the callkit call hangs up the voice call', () async {
      await acceptAndConnect();
      callkit.emit(CallkitSignalKind.ended, id);
      await settle();
      expect(call.endCalls, 1);
      expect(sender.sent.last, (id, 'ended'));
    });

    test('notification buttons drive the call', () async {
      await acceptAndConnect();
      ui.controller.add(OngoingCallAction.toggleMute);
      await settle();
      expect(call.micMuted, isTrue);
      expect(ui.shown.last.status, 'Muted');
      expect(ui.shown.last.muted, isTrue);

      ui.controller.add(OngoingCallAction.toggleSpeaker);
      await settle();
      expect(call.speakerOn, isFalse);
      expect(ui.shown.last.speakerOn, isFalse);

      ui.controller.add(OngoingCallAction.open);
      await settle();
      expect(opened, <(String, VoiceCallMode?)>[
        (thread, VoiceCallMode.agents),
      ]);

      ui.controller.add(OngoingCallAction.hangUp);
      await settle();
      expect(call.endCalls, 1);
      expect(sender.sent.last, (id, 'ended'));
    });

    test('an unchanged call does not re-post the notification', () async {
      await acceptAndConnect();
      final int before = ui.shown.length;
      call.notifyListeners();
      call.notifyListeners();
      await settle();
      expect(ui.shown.length, before);
    });
  });

  group('the microphone at accept', () {
    test('missing at the ring: callkit starts no service on Accept', () async {
      mic.granted = false;
      await ring();
      expect(callkit.shown.single.callingNotification?.showNotification, false);
      expect(service.book[id]!.serviceDeferred, isTrue);
    });

    test(
      'asked before accepted, then the service starts under the call id',
      () async {
        mic
          ..granted = false
          ..pending = Completer<bool>();
        await ring();
        callkit.emit(CallkitSignalKind.accept, id);
        await settle();
        // Waiting for the answer: nothing has gone out, no service yet.
        expect(mic.requests, 1);
        expect(sender.sent, isEmpty);
        expect(callkit.started, isEmpty);
        expect(starter.started, isEmpty);

        mic.pending!.complete(true);
        await settle();
        expect(callkit.started.single.id, id);
        expect(sender.sent, <(String, String)>[(id, 'accepted')]);
        expect(starter.started.single.callId, id);
        expect(service.sessionKey, id);
      },
    );

    test(
      'granted at the ring: no question, callkit runs the service itself',
      () async {
        await ring();
        expect(
          callkit.shown.single.callingNotification?.showNotification,
          true,
        );
        callkit.emit(CallkitSignalKind.accept, id);
        await settle();
        expect(mic.requests, 0);
        expect(callkit.started, isEmpty);
        expect(sender.sent, <(String, String)>[(id, 'accepted')]);
      },
    );

    test('refused: declined, the ring ends, a short notice', () async {
      mic
        ..granted = false
        ..grantOnRequest = false;
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      expect(sender.sent, <(String, String)>[(id, 'declined')]);
      expect(callkit.ended, <String>[id]);
      expect(callkit.started, isEmpty);
      expect(starter.started, isEmpty);
      expect(ui.notices, hasLength(1));
      expect(service.book[id]!.status, IncomingCallStatus.declined);
    });

    test('the host ending the ring during the question wins', () async {
      mic
        ..granted = false
        ..pending = Completer<bool>();
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      frames.add(stateFrame(id, 'missed'));
      await settle();
      mic.pending!.complete(true);
      await settle();
      expect(sender.sent, isEmpty);
      expect(starter.started, isEmpty);
      expect(callkit.started, isEmpty);
      expect(callkit.missed, isEmpty);
      expect(service.book[id]!.status, IncomingCallStatus.missed);
    });
  });

  group("the host's echo", () {
    test('missed stops the ring and leaves the missed-call notice', () async {
      await ring();
      frames.add(stateFrame(id, 'missed'));
      await settle();
      expect(callkit.ended, <String>[id]);
      expect(callkit.missed.single.id, id);
      // The plugin's own decline for that end is not reported.
      expect(sender.sent, isEmpty);
      expect(service.book[id]!.status, IncomingCallStatus.missed);
    });

    test('accepted elsewhere stops the ring, sends nothing', () async {
      await ring();
      frames.add(stateFrame(id, 'accepted'));
      await settle();
      expect(callkit.ended, <String>[id]);
      expect(callkit.missed, isEmpty);
      expect(sender.sent, isEmpty);
      expect(service.book[id]!.status, IncomingCallStatus.answeredElsewhere);
    });

    test('declined or ended from elsewhere stops the ring', () async {
      await ring();
      frames.add(stateFrame(id, 'ended'));
      await settle();
      expect(callkit.ended, <String>[id]);
      expect(sender.sent, isEmpty);
    });

    test('our own accepted echo changes nothing', () async {
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      frames.add(stateFrame(id, 'accepted'));
      await settle();
      expect(service.sessionKey, id);
      expect(call.endCalls, 0);
    });

    test('a late accept counted as missed keeps the live call', () async {
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      call.goLive();
      frames.add(stateFrame(id, 'missed'));
      await settle();
      expect(call.endCalls, 0);
      expect(service.sessionKey, id);
    });

    test('ended from the host ends the live call, and ended is not sent '
        'back', () async {
      await ring();
      callkit.emit(CallkitSignalKind.accept, id);
      await settle();
      call.goLive();
      frames.add(stateFrame(id, 'ended'));
      await settle();
      expect(call.endCalls, 1);
      expect(sender.sent, <(String, String)>[(id, 'accepted')]);
      expect(callkit.ended, <String>[id]);
    });

    test('an echo for an unknown call is ignored', () async {
      frames.add(stateFrame('nope', 'missed'));
      await settle();
      expect(callkit.ended, isEmpty);
    });
  });

  test(
    'our notification is posted again after callkit posts its own',
    () async {
      await service.dispose();
      service = IncomingCallService(
        hostFrames: frames.stream,
        callkit: callkit,
        sender: sender,
        ui: ui,
        call: call,
        starter: starter.start,
        openChat: (String chatId, VoiceCallMode? mode) {},
        mic: mic,
        now: () => now,
        newCallKey: () => 'user-call-1',
        repostDelays: const <Duration>[Duration(milliseconds: 5)],
      )..start();
      call.begin(chatId: thread, mode: VoiceCallMode.agents);
      call.goLive();
      await settle();
      final int before = ui.shown.length;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ui.shown.length, greaterThan(before));
      expect(ui.shown.last, ui.shown[before - 1]);

      // No repost for a call that is over.
      call.finish();
      await settle();
      final int after = ui.shown.length;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ui.shown.length, after);
    },
  );

  group('a call the user started', () {
    test(
      'runs the callkit ongoing call and our notification, no frames',
      () async {
        call.begin(
          chatId: thread,
          mode: VoiceCallMode.agents,
          agentName: 'Crypto Desk',
        );
        await settle();
        // Not before the room is up: the microphone permission is asked in
        // between, and the foreground service must start with it.
        expect(callkit.started, isEmpty);

        call.goLive(agent: false);
        await settle();
        expect(callkit.started.single.id, 'user-call-1');
        expect(callkit.started.single.nameCaller, 'Crypto Desk');
        expect(callkit.connected, isEmpty);

        call.goLive();
        await settle();
        expect(callkit.connected, <String>['user-call-1']);
        expect(ui.shown.last.callKey, 'user-call-1');

        call.finish();
        await settle();
        expect(callkit.ended, <String>['user-call-1']);
        expect(ui.cancelled, <String>['user-call-1']);
        expect(sender.sent, isEmpty);
      },
    );

    test('a normal chat keeps its title out of the notification', () async {
      call.begin(
        chatId: 'c0ffee00-0000-4000-8000-000000000000',
        mode: VoiceCallMode.chat,
      );
      call.goLive();
      await settle();
      expect(callkit.started.single.nameCaller, kOngoingChatCallName);
      expect(ui.shown.last.title, kOngoingChatCallName);
    });

    test('a failed start never touches callkit', () async {
      call.begin(chatId: thread, mode: VoiceCallMode.agents);
      call.finish(VoiceCallPhase.failed);
      await settle();
      expect(callkit.started, isEmpty);
      expect(callkit.ended, isEmpty);
    });

    test(
      'accepting an agent call during a user call swaps the sessions',
      () async {
        call.begin(chatId: 'other', mode: VoiceCallMode.agents);
        call.goLive();
        await settle();
        expect(service.sessionKey, 'user-call-1');

        await ring();
        callkit.emit(CallkitSignalKind.accept, id);
        await settle();
        // The real controller hangs the old call up first; the fake starter
        // just begins the new one, which the service reads as a new call.
        expect(callkit.ended, contains('user-call-1'));
        expect(service.sessionKey, id);
      },
    );
  });
}
