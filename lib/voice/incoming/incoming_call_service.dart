// lib/voice/incoming/incoming_call_service.dart
//
// The phone side of "the agent calls the user" (docs/WIRE_CONTRACT.md, "The
// agent calls the user"; spec §6.3), and the ongoing-call notification of
// every voice call.
//
//  1. A `voice_call_incoming` frame rings the callkit UI (full screen over the
//     lock screen, or a heads-up call). A known `call_id` is a no-op; an
//     expired one never rings.
//  2. Accept → the microphone permission first (asked now if it is still
//     missing; refused → `declined` and a short notice), then `voice_call_state
//     accepted`, the Agents thread opens and the voice session starts with
//     `initiatedByAgent`, the call id and the reason. Decline → `declined`.
//     The local ring running out sends nothing: `missed` is the host's to
//     decide, and it does so at the ring's end.
//     The app never shows over the lock screen: the ring there is callkit's
//     own screen; an accepted call runs its audio in the callkit foreground
//     service with our notification, the user is asked to unlock, and the
//     app appears only after that.
//  3. The host's echo is the truth for a ring: any state other than ringing
//     stops it on this device (`accepted` that this device did not send =
//     answered on another device).
//  4. While any voice call runs (agent-started or user-started) the callkit
//     "ongoing call" holds the phoneCall + microphone foreground service, and
//     our own notification takes its place with Hang up, Mute, Speaker and
//     Volume buttons. When the call ends: `ended` (for an agent call), the
//     callkit call ends and the notification goes.
//
// Privacy: the reason travels only to the voice worker. Log lines carry the
// call id and states, never the reason or a transcript.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/agents/agents_voice_call_frames.dart';
import 'package:chuk_chat/voice/incoming/incoming_call.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_book.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_mapping.dart';
import 'package:chuk_chat/voice/incoming/incoming_call_ports.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';

/// The notice when a call was refused for want of the microphone.
const String kMicNeededNotice =
    'Calls need the microphone. Allow it in Settings, Voice calls.';

class IncomingCallService {
  IncomingCallService({
    required this.hostFrames,
    required this.callkit,
    required this.sender,
    required this.ui,
    required this.call,
    required this.starter,
    required this.openChat,
    required this.mic,
    IncomingCallBook? book,
    DateTime Function()? now,
    String Function()? newCallKey,
    this.repostDelays = const <Duration>[
      Duration(milliseconds: 600),
      Duration(seconds: 2),
    ],
  }) : book = book ?? IncomingCallBook(),
       _now = now ?? DateTime.now,
       _newCallKey = newCallKey ?? (() => const Uuid().v4());

  /// The host's voice-call frames (`AgentsVoiceCallFrames.frames`).
  final Stream<Map<String, dynamic>> hostFrames;
  final CallkitPort callkit;
  final CallStateSender sender;
  final OngoingCallUi ui;
  final VoiceCallView call;
  final IncomingCallStarter starter;
  final CallChatOpener openChat;
  final MicPermission mic;
  final IncomingCallBook book;
  final DateTime Function() _now;
  final String Function() _newCallKey;

  /// callkit posts its own ongoing-call notification when a call starts, is
  /// accepted and connects. Ours takes its place again after these delays.
  final List<Duration> repostDelays;

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  final List<Timer> _reposts = <Timer>[];
  _Session? _session;
  OngoingCallSnapshot? _shown;
  bool _started = false;

  /// The voice call this service mirrors right now, if any (tests).
  @visibleForTesting
  String? get sessionKey => _session?.key;

  /// Starts listening. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    _subs
      ..add(hostFrames.listen(onHostFrame, onError: _ignore))
      ..add(callkit.signals.listen(onCallkitSignal, onError: _ignore))
      ..add(ui.actions.listen(onUiAction, onError: _ignore));
    call.addListener(_onCall);
    _onCall();
  }

  Future<void> dispose() async {
    if (!_started) return;
    _started = false;
    call.removeListener(_onCall);
    _cancelReposts();
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  static void _ignore(Object error) {
    if (kDebugMode) {
      debugPrint('[incoming-call] stream error: ${error.runtimeType}');
    }
  }

  // ── Host frames ─────────────────────────────────────────────────────

  void onHostFrame(Map<String, dynamic> frame) {
    switch (frame['type']) {
      case AgentsVoiceCallFrames.incomingType:
        final IncomingCall? incoming = IncomingCall.fromFrame(
          frame,
          now: _now(),
        );
        if (incoming != null) _onIncoming(incoming);
      case AgentsVoiceCallFrames.stateType:
        final HostCallState? state = HostCallState.fromFrame(frame);
        if (state != null) _onHostState(state);
    }
  }

  void _onIncoming(IncomingCall incoming) {
    final IncomingAdmission admission = book.admit(incoming, _now());
    if (kDebugMode) {
      debugPrint(
        '[incoming-call] ${incoming.callId} ${admission.name} '
        '(urgency=${incoming.urgency.name})',
      );
    }
    if (admission != IncomingAdmission.ring) return;
    unawaited(_ring(book[incoming.callId]!));
  }

  /// Shows the ring. callkit starts its ongoing-call foreground service on
  /// Accept by itself only when the microphone is granted already: the
  /// service takes its microphone type at start. Otherwise the service waits
  /// for the permission ([_accept]).
  Future<void> _ring(IncomingCallEntry entry) async {
    bool micReady;
    try {
      micReady = await mic.isGranted();
    } catch (_) {
      micReady = false;
    }
    if (entry.status != IncomingCallStatus.ringing) return;
    if (!micReady) {
      final params = incomingCallkitParams(
        entry.call,
        _now(),
        startServiceOnAccept: false,
      );
      if (params == null) {
        entry.status = IncomingCallStatus.expired;
        return;
      }
      entry
        ..params = params
        ..serviceDeferred = true;
    }
    await _quietly(() => callkit.showIncoming(entry.params!));
  }

  void _onHostState(HostCallState echo) {
    final IncomingCallEntry? entry = book[echo.callId];
    if (entry == null) return;
    if (kDebugMode) {
      debugPrint(
        '[incoming-call] ${echo.callId} host=${echo.state} '
        'local=${entry.status.name}',
      );
    }
    switch (entry.status) {
      case IncomingCallStatus.ringing:
      case IncomingCallStatus.accepting:
        final bool wasRinging = entry.status == IncomingCallStatus.ringing;
        entry.status = switch (echo.state) {
          AgentsVoiceCallFrames.accepted =>
            IncomingCallStatus.answeredElsewhere,
          AgentsVoiceCallFrames.declined => IncomingCallStatus.declined,
          AgentsVoiceCallFrames.missed => IncomingCallStatus.missed,
          _ => IncomingCallStatus.ended,
        };
        // Its own decline event comes back and is ignored: no longer ringing.
        unawaited(_quietly(() => callkit.end(entry.callId)));
        final params = entry.params;
        if (wasRinging &&
            echo.state == AgentsVoiceCallFrames.missed &&
            params != null) {
          unawaited(_quietly(() => callkit.showMissed(params)));
        }
      case IncomingCallStatus.accepted:
        // `accepted` is our own echo. `declined`/`missed` means the host
        // counted the answer as too late; the voice session with the worker
        // runs regardless, so it stays. Only `ended` ends it.
        if (echo.state != AgentsVoiceCallFrames.ended) return;
        entry.sent.add(AgentsVoiceCallFrames.ended);
        final _Session? session = _session;
        if (session != null && session.key == entry.callId) {
          unawaited(_quietly(call.end));
        } else {
          entry.status = IncomingCallStatus.ended;
          unawaited(_quietly(() => callkit.end(entry.callId)));
        }
      case IncomingCallStatus.declined:
      case IncomingCallStatus.missed:
      case IncomingCallStatus.ended:
      case IncomingCallStatus.answeredElsewhere:
      case IncomingCallStatus.expired:
        break;
    }
  }

  // ── Callkit ─────────────────────────────────────────────────────────

  void onCallkitSignal(CallkitSignal signal) {
    final IncomingCallEntry? entry = book[signal.id];
    final _Session? session = _session;
    if (kDebugMode) {
      debugPrint(
        '[incoming-call] callkit ${signal.kind.name} ${signal.id} '
        'local=${entry?.status.name}',
      );
    }
    switch (signal.kind) {
      case CallkitSignalKind.accept:
        if (entry == null) {
          // A ring this service does not know (left over from an earlier
          // run): nothing can be started for it.
          unawaited(_quietly(() => callkit.end(signal.id)));
          return;
        }
        if (entry.status != IncomingCallStatus.ringing) return;
        unawaited(_accept(entry));
      case CallkitSignalKind.decline:
        if (entry == null || entry.status != IncomingCallStatus.ringing) return;
        entry.status = IncomingCallStatus.declined;
        _send(entry, AgentsVoiceCallFrames.declined);
      case CallkitSignalKind.timeout:
        if (entry == null || entry.status != IncomingCallStatus.ringing) return;
        // No frame: a ring nobody answers becomes `missed` on the host at
        // `expires_at`, and `missed` is not the app's to report.
        entry.status = IncomingCallStatus.missed;
      case CallkitSignalKind.ended:
        if (session != null && session.key == signal.id) {
          // Hung up from the OS (the call ended in Telecom).
          unawaited(_quietly(call.end));
          return;
        }
        if (entry == null) return;
        if (entry.status == IncomingCallStatus.ringing ||
            entry.status == IncomingCallStatus.accepting ||
            entry.status == IncomingCallStatus.accepted) {
          entry.status = IncomingCallStatus.ended;
          _send(entry, AgentsVoiceCallFrames.ended);
        }
    }
  }

  Future<void> _accept(IncomingCallEntry entry) async {
    entry.status = IncomingCallStatus.accepting;
    // Accepted on the lock screen: ask to unlock. The app itself never shows
    // over the lock screen; the call's audio runs in the callkit service.
    unawaited(_quietly(ui.requestUnlock));

    // The microphone BEFORE `accepted` and before the foreground service: a
    // service started without it has no microphone type, and the agent hears
    // nothing once the app is in the background.
    bool granted;
    try {
      granted = await mic.isGranted() || await mic.request();
    } catch (_) {
      granted = false;
    }
    if (entry.status != IncomingCallStatus.accepting) return;
    if (!granted) {
      if (kDebugMode) debugPrint('[incoming-call] ${entry.callId} no mic');
      entry.status = IncomingCallStatus.declined;
      _send(entry, AgentsVoiceCallFrames.declined);
      unawaited(_quietly(() => callkit.end(entry.callId)));
      unawaited(_quietly(() => ui.notice(kMicNeededNotice)));
      return;
    }
    if (entry.serviceDeferred) {
      // The ring was shown without callkit's own service on Accept; start
      // it now, with the permission in place, under the same id.
      await _quietly(
        () => callkit.startOutgoing(
          outgoingCallkitParams(id: entry.callId, name: entry.call.agentName),
        ),
      );
      if (entry.status != IncomingCallStatus.accepting) return;
    }

    entry.status = IncomingCallStatus.accepted;
    _send(entry, AgentsVoiceCallFrames.accepted);
    try {
      await starter(entry.call);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[incoming-call] start failed: ${e.runtimeType}');
      }
      final _Session? session = _session;
      if (session == null || session.key != entry.callId) {
        entry.status = IncomingCallStatus.ended;
        _send(entry, AgentsVoiceCallFrames.ended);
        unawaited(_quietly(() => callkit.end(entry.callId)));
      }
    }
  }

  void _send(IncomingCallEntry entry, String state) {
    if (!entry.sent.add(state)) return;
    unawaited(_quietly(() => sender.send(entry.callId, state)));
  }

  // ── The running voice call ──────────────────────────────────────────

  void _onCall() {
    final _Session? current = _session;
    if (current != null && !_stillRuns(current)) _close(current);

    if (_session == null && call.isActive) {
      final String? id = call.callId;
      final IncomingCallEntry? entry = id == null ? null : book[id];
      if (entry != null && entry.status == IncomingCallStatus.accepted) {
        _session = _Session(
          key: entry.callId,
          entry: entry,
          chatId: call.chatId,
          startedAt: call.startedAt,
        );
        // callkit posts its own ongoing call as the accept lands.
        _scheduleReposts();
      } else if (call.phase == VoiceCallPhase.live) {
        // A call the user started (the microphone permission is settled by
        // now, so the foreground service gets its microphone type).
        final _Session session = _Session(
          key: _newCallKey(),
          chatId: call.chatId,
          startedAt: call.startedAt,
        );
        _session = session;
        unawaited(
          _quietly(
            () => callkit.startOutgoing(
              outgoingCallkitParams(id: session.key, name: _titleFor(session)),
            ),
          ),
        );
        _scheduleReposts();
      }
    }

    final _Session? session = _session;
    if (session == null) return;
    if (!session.connected &&
        call.phase == VoiceCallPhase.live &&
        call.agentPresent) {
      session.connected = true;
      session.connectedAt = _now();
      unawaited(_quietly(() => callkit.setConnected(session.key)));
      _scheduleReposts();
    }
    _show(_snapshotFor(session));
  }

  /// The running call is still the one [session] mirrors.
  bool _stillRuns(_Session session) {
    if (!call.isActive) return false;
    if (call.startedAt != session.startedAt) return false;
    if (call.chatId != session.chatId) return false;
    final IncomingCallEntry? entry = session.entry;
    return entry == null || call.callId == entry.callId;
  }

  void _close(_Session session) {
    _session = null;
    _cancelReposts();
    _shown = null;
    if (kDebugMode) {
      debugPrint('[incoming-call] session ${session.key} over');
    }
    unawaited(_quietly(() => ui.cancel(session.key)));
    unawaited(_quietly(() => callkit.end(session.key)));
    final IncomingCallEntry? entry = session.entry;
    if (entry != null) {
      entry.status = IncomingCallStatus.ended;
      _send(entry, AgentsVoiceCallFrames.ended);
    }
  }

  String _titleFor(_Session session) {
    final IncomingCallEntry? entry = session.entry;
    if (entry != null) return entry.call.agentName;
    if (call.mode == VoiceCallMode.agents) {
      final String? name = call.agentName?.trim();
      return (name == null || name.isEmpty)
          ? IncomingCall.defaultAgentName
          : name;
    }
    return kOngoingChatCallName;
  }

  OngoingCallSnapshot _snapshotFor(_Session session) {
    final bool connected = session.connected;
    final String status = !connected
        ? 'Connecting…'
        : (call.micMuted ? 'Muted' : 'On call');
    return OngoingCallSnapshot(
      callKey: session.key,
      title: _titleFor(session),
      status: status,
      muted: call.micMuted,
      speakerOn: call.speakerOn,
      canSwitchSpeaker: call.canSwitchSpeaker,
      connectedAt: session.connectedAt,
    );
  }

  void _show(OngoingCallSnapshot snapshot) {
    if (snapshot == _shown) return;
    _shown = snapshot;
    unawaited(_quietly(() => ui.show(snapshot)));
  }

  void _scheduleReposts() {
    _cancelReposts();
    for (final Duration delay in repostDelays) {
      _reposts.add(
        Timer(delay, () {
          final OngoingCallSnapshot? shown = _shown;
          if (shown == null || _session?.key != shown.callKey) return;
          unawaited(_quietly(() => ui.show(shown)));
        }),
      );
    }
  }

  void _cancelReposts() {
    for (final Timer t in _reposts) {
      t.cancel();
    }
    _reposts.clear();
  }

  // ── Notification buttons ────────────────────────────────────────────

  void onUiAction(OngoingCallAction action) {
    final _Session? session = _session;
    switch (action) {
      case OngoingCallAction.hangUp:
        if (call.isActive) unawaited(_quietly(call.end));
      case OngoingCallAction.toggleMute:
        if (session != null) {
          unawaited(_quietly(() => call.setMicMuted(!call.micMuted)));
        }
      case OngoingCallAction.toggleSpeaker:
        if (session != null && call.canSwitchSpeaker) {
          unawaited(_quietly(() => call.setSpeakerOn(!call.speakerOn)));
        }
      case OngoingCallAction.open:
        final String? chatId = session?.chatId ?? call.chatId;
        if (chatId != null && chatId.isNotEmpty) openChat(chatId, call.mode);
    }
  }

  static Future<void> _quietly(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (kDebugMode) debugPrint('[incoming-call] ${e.runtimeType}');
    }
  }
}

/// One voice call as the OS sees it: its callkit id, and the agent call it
/// answers (null for a call the user started).
class _Session {
  _Session({
    required this.key,
    required this.chatId,
    required this.startedAt,
    this.entry,
  });

  final String key;
  final IncomingCallEntry? entry;
  final String? chatId;
  final DateTime? startedAt;
  bool connected = false;
  DateTime? connectedAt;
}
