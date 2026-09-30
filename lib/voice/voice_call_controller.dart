// lib/voice/voice_call_controller.dart
//
// The one voice call the app can hold at a time: a LiveKit room shared with
// the voice worker (agent_name `chuk-voice`). The worker is the mouth and the
// ears (docs/PERSONAL_AGENT_SPEC.md §5.1); work it cannot do itself comes
// back to this app as a `chuk.delegate` RPC and goes to the chat's
// [VoiceTaskDelegate].
//
// Privacy (CLAUDE.md "Privacy: Logging"): every debugPrint sits inside
// kDebugMode and never carries transcript text, a token or the token URL.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_call_service.dart';
import 'package:chuk_chat/voice/voice_call_store.dart';
import 'package:chuk_chat/voice/voice_location.dart';
import 'package:chuk_chat/voice/voice_protocol.dart';
import 'package:chuk_chat/voice/voice_tasks.dart';
import 'package:chuk_chat/voice/voice_transcript.dart';

class VoiceCallController extends ChangeNotifier {
  VoiceCallController._({
    VoiceLocationResolver? location,
    Future<bool> Function(VoiceTaskResult result)? sendResult,
    List<Duration>? resultBackoff,
  }) : _location = location ?? VoiceLocationResolver(),
       _sendResultOverride = sendResult,
       _resultBackoff = resultBackoff ?? kVoiceResultBackoff;

  /// A controller outside the app-wide one, for tests. [sendResult] stands
  /// in for the `chuk.task_result` RPC (true = delivered).
  @visibleForTesting
  factory VoiceCallController.forTesting({
    VoiceLocationResolver? location,
    Future<bool> Function(VoiceTaskResult result)? sendResult,
    List<Duration>? resultBackoff,
  }) => VoiceCallController._(
    location: location,
    sendResult: sendResult,
    resultBackoff: resultBackoff,
  );

  static final VoiceCallController _instance = VoiceCallController._();

  /// One call at a time, app-wide.
  static VoiceCallController get instance => _instance;

  /// How long the worker may take to join (and the preconnect buffer may
  /// hold the first words) before the call is given up.
  static const Duration _agentJoinTimeout = Duration(seconds: 25);

  /// A worker that leaves is given this long to come back before the call
  /// ends.
  static const Duration _agentLeftGrace = Duration(seconds: 3);

  /// The longest call the app holds. At the limit it hangs up (a call left
  /// running by mistake costs worker, STT and TTS minutes).
  static const Duration maxCallDuration = Duration(minutes: 60);

  /// livekit-agents publishes its state here (`listening`, `thinking`,
  /// `speaking`, ...). Not exported by livekit_client.
  static const String _agentStateAttribute = 'lk.agent.state';

  VoiceCallPhase _phase = VoiceCallPhase.idle;
  bool _micMuted = false;
  bool _agentSpeaking = false;
  bool _agentThinking = false;
  bool _agentPresent = false;
  bool? _speakerOn;
  String? _chatId;
  String? _callId;
  VoiceCallMode? _mode;
  String? _agentName;
  String? _error;
  DateTime? _startedAt;
  final VoiceTranscript _transcript = VoiceTranscript();
  List<VoiceTurn> _turns = const <VoiceTurn>[];
  final List<VoiceCard> _cardList = <VoiceCard>[];
  List<VoiceCard> _cards = const <VoiceCard>[];
  final Map<String, VoiceToolActivity> _tools = <String, VoiceToolActivity>{};
  List<VoiceToolActivity> _runningTools = const <VoiceToolActivity>[];

  /// Cards held per call; the oldest fall off (the prototype's cap).
  static const int _maxCards = 60;

  lk.Room? _room;
  lk.EventsListener<lk.RoomEvent>? _roomListener;
  String? _agentIdentity;
  final VoiceTaskLedger _tasks = VoiceTaskLedger();
  final VoiceLocationResolver _location;
  final Future<bool> Function(VoiceTaskResult result)? _sendResultOverride;
  final List<Duration> _resultBackoff;
  StreamSubscription<VoiceTaskResult>? _resultSub;
  Timer? _agentJoinTimer;
  Timer? _agentLeftTimer;
  Timer? _callLimitTimer;
  Future<VoiceCallRecord?>? _finishing;

  /// Bumped whenever a call starts or ends. Every async continuation and
  /// room callback checks it, so a late event from an old room is dropped.
  int _generation = 0;

  final StreamController<VoiceCallRecord> _ended =
      StreamController<VoiceCallRecord>.broadcast();
  final StreamController<VoiceCallPhase> _phases =
      StreamController<VoiceCallPhase>.broadcast();
  VoiceCallPhase _lastEmittedPhase = VoiceCallPhase.idle;

  // ── State ─────────────────────────────────────────────────────────────

  VoiceCallPhase get phase => _phase;
  bool get micMuted => _micMuted;
  bool get agentSpeaking => _agentSpeaking;
  String? get chatId => _chatId;
  VoiceCallMode? get mode => _mode;

  /// Live transcript of the current (or last) call; partials are replaced
  /// by their finals.
  List<VoiceTurn> get turns => _turns;

  /// What the agent showed on screen in this call (`ui.card`), oldest first.
  /// A card re-sent with the same id replaces the older copy.
  List<VoiceCard> get cards => _cards;

  /// Worker tools running right now (`ui.tool`), oldest first. The panel
  /// shows the newest as a status line ("Searching the web…").
  List<VoiceToolActivity> get runningTools => _runningTools;

  /// Why the last call failed, safe to show. Null unless [phase] is
  /// [VoiceCallPhase.failed].
  String? get error => _error;

  /// True while a call holds the room: connecting, live or hanging up.
  bool get isActive =>
      _phase == VoiceCallPhase.connecting ||
      _phase == VoiceCallPhase.live ||
      _phase == VoiceCallPhase.ending;

  /// True once the voice worker is in the room.
  bool get agentPresent => _agentPresent;

  /// The worker is working out its answer (`lk.agent.state` = thinking).
  bool get agentThinking => _agentThinking;

  /// The id of an agent-started call (spec §6.3), as passed to [start].
  String? get callId => _callId;

  /// Whether the output can be switched between speaker and earpiece
  /// (phones only; a headset always wins).
  bool get canSwitchSpeaker =>
      !kIsWeb && lk.AudioManager.instance.canSwitchSpeakerphone;

  /// True when the speaker is the preferred output (LiveKit's default).
  bool get speakerOn =>
      _speakerOn ?? lk.AudioManager.instance.isSpeakerOutputPreferred;

  /// Every phase change, in order. For a layer that mirrors the call
  /// elsewhere (the incoming-call UI calls `setCallConnected` on
  /// [VoiceCallPhase.live] and `endCall` on ended/failed).
  Stream<VoiceCallPhase> get phaseChanges => _phases.stream;

  /// The name passed to [start], for the panel's transcript labels.
  String? get agentName => _agentName;

  DateTime? get startedAt => _startedAt;

  /// Fires once for every call that ends with a final turn or a card —
  /// hung up here, ended by the worker, or dropped by the network. The same
  /// record [end] returns. It is already saved in `VoiceCallStore` when it
  /// fires. Listen to the controller itself for phase changes.
  Stream<VoiceCallRecord> get onCallEnded => _ended.stream;

  // ── Start ─────────────────────────────────────────────────────────────

  /// Starts a call for [chatId]. A call that is still running (in any chat)
  /// is hung up first. Failures do not throw: [phase] becomes
  /// [VoiceCallPhase.failed] and [error] says why.
  ///
  /// [callId], [callReason] and [initiatedByAgent] describe a call the agent
  /// started (spec §6.3); they go to the worker in the dispatch metadata.
  Future<void> start({
    required String chatId,
    required VoiceCallMode mode,
    String? chatTitle,
    String? agentName,
    String context = '',
    VoiceTaskDelegate? delegate,
    String? sttLanguage,
    String? callId,
    String? callReason,
    bool initiatedByAgent = false,
  }) async {
    final Future<VoiceCallRecord?>? finishing = _finishing;
    if (finishing != null) await finishing;
    if (isActive) await end();

    final int gen = ++_generation;
    _chatId = chatId;
    _mode = mode;
    _agentName = agentName;
    _callId = callId;
    _tasks.reset(delegate);
    _location.resetForNewCall();
    _error = null;
    _micMuted = false;
    _agentSpeaking = false;
    _agentThinking = false;
    _agentPresent = false;
    _agentIdentity = null;
    _startedAt = DateTime.now();
    _transcript.clear();
    _turns = const <VoiceTurn>[];
    _cardList.clear();
    _cards = const <VoiceCard>[];
    _tools.clear();
    _runningTools = const <VoiceToolActivity>[];
    _setPhase(VoiceCallPhase.connecting);
    _armCallLimit(gen, maxCallDuration);

    if (!VoiceCallService.isAvailable) {
      await _finish(
        VoiceCallPhase.failed,
        error: 'Voice calls are not set up in this build',
      );
      return;
    }

    try {
      await _ensureMicPermission();
      if (gen != _generation) return;

      final String callerId = await VoiceCallService.callerId();
      if (gen != _generation) return;
      final String identity = '${VoiceProtocol.identityPrefix}$callerId';
      final String roomName = '${VoiceProtocol.roomPrefix}${const Uuid().v4()}';
      final Map<String, dynamic> metadata = VoiceProtocol.dispatchMetadata(
        userId: callerId,
        mode: mode,
        chatTitle: chatTitle,
        agentName: agentName,
        context: context,
        sttLanguage: VoiceProtocol.resolveSttLanguage(
          sttLanguage,
          PlatformDispatcher.instance.locale.languageCode,
        ),
        delegateAvailable: delegate != null,
        initiatedByAgent: initiatedByAgent,
        callId: callId,
        callReason: callReason,
      );
      final VoiceCredentials credentials =
          await VoiceCallService.fetchCredentials(
            VoiceProtocol.tokenRequest(
              roomName: roomName,
              participantIdentity: identity,
              participantName: identity,
              metadata: metadata,
            ),
          );
      if (gen != _generation) return;

      final lk.Room room = lk.Room(
        roomOptions: const lk.RoomOptions(
          // Speech bitrate (24 kbps) + DTX + RED, as the prototype: less
          // bandwidth and steadier turns under packet loss.
          defaultAudioPublishOptions: lk.AudioPublishOptions(
            encoding: lk.AudioEncoding.presetSpeech,
            dtx: true,
            red: true,
          ),
        ),
      );
      _room = room;
      _attach(room, gen);
      await _connect(room, credentials, gen);
      if (gen != _generation) return;

      if (_micMuted) {
        await room.localParticipant?.setMicrophoneEnabled(false);
      }
      final bool? speaker = _speakerOn;
      if (speaker != null && canSwitchSpeaker) {
        await lk.AudioManager.instance.setSpeakerOutputPreferred(speaker);
      }
      if (gen != _generation) return;
      _refreshAgent(gen);
      if (!_agentPresent) _armAgentJoinTimer(gen);
      _setPhase(VoiceCallPhase.live);
      // The delegate may have been detached while the room connected.
      _listenForResults(_tasks.delegate, gen);
      if (kDebugMode) {
        debugPrint('[VoiceCall] live (mode=${mode.name})');
      }
    } catch (e) {
      if (gen != _generation) return;
      if (kDebugMode) {
        debugPrint('[VoiceCall] start failed: ${e.runtimeType}');
      }
      await _finish(VoiceCallPhase.failed, error: _describe(e));
    }
  }

  /// Joins with the preconnect buffer when the platform supports it: the
  /// microphone records while the room connects, and the first words reach
  /// the worker once it is up. When the buffer cannot start, joins plainly.
  Future<void> _connect(
    lk.Room room,
    VoiceCredentials credentials,
    int gen,
  ) async {
    bool connectStarted = false;
    try {
      await room.withPreConnectAudio<void>(
        () {
          connectStarted = true;
          return room.connect(
            credentials.serverUrl,
            credentials.participantToken,
          );
        },
        timeout: _agentJoinTimeout,
        onError: (Object e) {
          if (kDebugMode) {
            debugPrint('[VoiceCall] preconnect buffer: ${e.runtimeType}');
          }
        },
      );
    } catch (e) {
      if (connectStarted || gen != _generation) rethrow;
      if (kDebugMode) {
        debugPrint('[VoiceCall] preconnect unavailable (${e.runtimeType})');
      }
      await room.connect(credentials.serverUrl, credentials.participantToken);
      if (gen != _generation) return;
      await room.localParticipant?.setMicrophoneEnabled(true);
    }
  }

  Future<void> _ensureMicPermission() async {
    // Android asks here; iOS/macOS are asked by WebRTC itself; the Linux
    // desktop has no runtime permission.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final PermissionStatus status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw const VoiceCallException('A call needs the microphone');
    }
  }

  // ── Room wiring ───────────────────────────────────────────────────────

  void _attach(lk.Room room, int gen) {
    room.registerTextStreamHandler(
      VoiceTranscriptionAttributes.topic,
      (lk.TextStreamReader reader, String identity) =>
          _onTranscriptionStream(room, gen, reader, identity),
    );
    room.registerRpcMethod(
      VoiceProtocol.delegateMethod,
      (lk.RpcInvocationData data) => _handleDelegateRpc(data.payload),
    );
    room.registerRpcMethod(VoiceProtocol.openLinkMethod, _onOpenLink);
    room.registerRpcMethod(
      VoiceProtocol.getLocationMethod,
      (_) => _location.answer(),
    );
    room.registerRpcMethod(
      VoiceProtocol.getDeviceStatusMethod,
      (_) async => VoiceProtocol.notAvailable(),
    );

    final lk.EventsListener<lk.RoomEvent> listener = room.createListener();
    listener
      ..on<lk.RoomDisconnectedEvent>(
        (lk.RoomDisconnectedEvent e) => _onDisconnected(gen, e.reason),
      )
      ..on<lk.ParticipantConnectedEvent>((_) => _refreshAgent(gen))
      ..on<lk.ParticipantDisconnectedEvent>((_) => _onParticipantLeft(gen))
      ..on<lk.ParticipantAttributesChanged>((_) => _refreshAgent(gen))
      ..on<lk.ActiveSpeakersChangedEvent>((_) => _refreshAgent(gen))
      ..on<lk.DataReceivedEvent>((lk.DataReceivedEvent e) => _onData(gen, e));
    _roomListener = listener;
  }

  /// `ui.card` and `ui.tool` from the worker (its UI channel).
  void _onData(int gen, lk.DataReceivedEvent event) {
    if (gen != _generation) return;
    switch (event.topic) {
      case VoiceProtocol.cardTopic:
        final VoiceCard? card = VoiceProtocol.parseCard(event.data);
        if (card == null) return;
        _cardList.removeWhere((VoiceCard c) => c.id == card.id);
        _cardList.add(card);
        if (_cardList.length > _maxCards) {
          _cardList.removeRange(0, _cardList.length - _maxCards);
        }
        _cards = List<VoiceCard>.unmodifiable(_cardList);
        notifyListeners();
      case VoiceProtocol.toolTopic:
        final VoiceToolActivity? update = VoiceProtocol.parseToolActivity(
          event.data,
        );
        if (update == null) return;
        final VoiceToolActivity merged =
            _tools[update.callId]?.mergedWith(update) ?? update;
        if (merged.isRunning) {
          _tools[merged.callId] = merged;
        } else {
          _tools.remove(merged.callId);
        }
        _runningTools = List<VoiceToolActivity>.unmodifiable(_tools.values);
        notifyListeners();
    }
  }

  void _onTranscriptionStream(
    lk.Room room,
    int gen,
    lk.TextStreamReader reader,
    String identity,
  ) {
    final lk.TextStreamInfo? info = reader.info;
    if (info == null || gen != _generation) return;
    final String role = identity == room.localParticipant?.identity
        ? VoiceTurn.roleUser
        : VoiceTurn.roleAssistant;
    final String streamId = info.id;
    final String segmentId =
        info.attributes[VoiceTranscriptionAttributes.segmentId] ?? streamId;
    final bool headerFinal = VoiceTranscriptionAttributes.parseFinal(
      info.attributes,
    );
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(
      info.timestamp,
      isUtc: true,
    ).toLocal();

    reader.listen(
      (chunk) {
        if (gen != _generation) return;
        final String text;
        try {
          text = utf8.decode(chunk.content);
        } catch (_) {
          return;
        }
        final bool changed = _transcript.applyChunk(
          role: role,
          segmentId: segmentId,
          streamId: streamId,
          text: text,
          isFinal: headerFinal,
          at: at,
        );
        if (changed) _publishTurns();
      },
      onDone: () {
        if (gen != _generation) return;
        // The agent's final flag rides in the stream trailer, merged into
        // the info just before the stream closes.
        final Map<String, String> attributes =
            reader.info?.attributes ?? const <String, String>{};
        if (VoiceTranscriptionAttributes.parseFinal(attributes) &&
            _transcript.finalizeSegment(role: role, segmentId: segmentId)) {
          _publishTurns();
        }
      },
      onError: (Object e) {
        if (kDebugMode) {
          debugPrint('[VoiceCall] transcription stream: ${e.runtimeType}');
        }
      },
      cancelOnError: true,
    );
  }

  void _publishTurns() {
    _turns = _transcript.turns;
    notifyListeners();
  }

  void _refreshAgent(int gen) {
    final lk.Room? room = _room;
    if (room == null || gen != _generation) return;
    final lk.RemoteParticipant? agent = room.agentParticipant;
    final bool present = agent != null;
    bool speaking = false;
    bool thinking = false;
    if (agent != null) {
      _agentIdentity = agent.identity;
      _agentJoinTimer?.cancel();
      _agentJoinTimer = null;
      _agentLeftTimer?.cancel();
      _agentLeftTimer = null;
      final String? state = agent.attributes[_agentStateAttribute];
      speaking = state == null ? agent.isSpeaking : state == 'speaking';
      thinking = state == 'thinking';
    }
    if (present == _agentPresent &&
        speaking == _agentSpeaking &&
        thinking == _agentThinking) {
      return;
    }
    _agentPresent = present;
    _agentSpeaking = speaking;
    _agentThinking = thinking;
    notifyListeners();
  }

  void _onParticipantLeft(int gen) {
    if (gen != _generation) return;
    final bool hadAgent = _agentPresent;
    _refreshAgent(gen);
    if (!hadAgent || _agentPresent || _phase != VoiceCallPhase.live) return;
    // The worker hung up (or crashed). Give it a moment to come back, then
    // end the call so the room does not sit there silent.
    _agentLeftTimer?.cancel();
    _agentLeftTimer = Timer(_agentLeftGrace, () {
      if (gen != _generation || _agentPresent) return;
      if (kDebugMode) debugPrint('[VoiceCall] agent left, ending');
      unawaited(_finish(VoiceCallPhase.ended));
    });
  }

  void _armAgentJoinTimer(int gen) {
    _agentJoinTimer?.cancel();
    _agentJoinTimer = Timer(_agentJoinTimeout, () {
      if (gen != _generation || _agentPresent) return;
      if (kDebugMode) debugPrint('[VoiceCall] agent did not join');
      unawaited(
        _finish(VoiceCallPhase.failed, error: 'The voice agent did not answer'),
      );
    });
  }

  void _onDisconnected(int gen, lk.DisconnectReason? reason) {
    if (gen != _generation || _phase == VoiceCallPhase.ending) return;
    if (kDebugMode) {
      debugPrint('[VoiceCall] room disconnected: ${reason?.name}');
    }
    final String? failure = _failureFor(reason);
    unawaited(
      _finish(
        failure == null ? VoiceCallPhase.ended : VoiceCallPhase.failed,
        error: failure,
      ),
    );
  }

  static String? _failureFor(lk.DisconnectReason? reason) {
    switch (reason) {
      case lk.DisconnectReason.duplicateIdentity:
        return 'The call moved to another device';
      case lk.DisconnectReason.joinFailure:
      case lk.DisconnectReason.stateMismatch:
      case lk.DisconnectReason.signalingConnectionFailure:
      case lk.DisconnectReason.reconnectAttemptsExceeded:
      case lk.DisconnectReason.signalClose:
        return 'The connection was lost';
      default:
        return null;
    }
  }

  // ── RPC from the worker ───────────────────────────────────────────────

  Future<String> _onOpenLink(lk.RpcInvocationData data) async {
    final Uri? uri = VoiceProtocol.openLinkTarget(data.payload);
    if (uri == null) {
      return VoiceProtocol.openLinkAnswer(ok: false, error: 'invalid url');
    }
    try {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return VoiceProtocol.openLinkAnswer(ok: ok);
    } catch (_) {
      return VoiceProtocol.openLinkAnswer(ok: false, error: 'could not open');
    }
  }

  /// `chuk.delegate`: start the task through the current delegate and track
  /// it until its result goes back.
  Future<String> _handleDelegateRpc(String payload) {
    final VoiceTaskDelegate? delegate = _tasks.delegate;
    final int gen = _generation;
    return VoiceProtocol.handleDelegate(
      payload,
      delegate,
      onStarted: (String taskId) =>
          gen == _generation && _tasks.started(delegate, taskId),
    );
  }

  void _listenForResults(VoiceTaskDelegate? delegate, int gen) {
    unawaited(_resultSub?.cancel());
    _resultSub = delegate?.results.listen((VoiceTaskResult result) {
      if (gen != _generation) return;
      _tasks.resolved(result.taskId);
      unawaited(_deliverResult(result, gen));
    });
  }

  /// The chat that owns [delegate] is going away (its screen was disposed).
  /// Drops it when it is the current one: `chuk.delegate` then answers
  /// `{"error":"no delegate"}`, and every task it started that has no result
  /// yet gets a failed `chuk.task_result` ("the chat was closed"), so the
  /// worker does not wait on it for the rest of the call. Does nothing for
  /// any other delegate.
  void detachDelegate(VoiceTaskDelegate delegate) {
    if (!identical(_tasks.delegate, delegate)) return;
    final List<String> orphans = _tasks.detach(delegate);
    unawaited(_resultSub?.cancel());
    _resultSub = null;
    final int gen = _generation;
    if (kDebugMode) {
      debugPrint('[VoiceCall] delegate detached, ${orphans.length} open tasks');
    }
    for (final String taskId in orphans) {
      unawaited(
        _deliverResult(
          VoiceTaskResult(
            taskId: taskId,
            status: VoiceTaskResult.statusFailed,
            result: VoiceProtocol.chatClosed,
          ),
          gen,
        ),
      );
    }
  }

  /// Sends a `chuk.task_result`, retrying after 1 s, 3 s and 6 s while the
  /// call is live (the worker may be reconnecting, or the RPC timed out).
  Future<bool> _deliverResult(VoiceTaskResult result, int gen) async {
    final bool delivered = await deliverWithRetry(
      () => _sendResultOnce(result),
      backoff: _resultBackoff,
      stillValid: () => gen == _generation && _phase == VoiceCallPhase.live,
    );
    if (!delivered && kDebugMode) {
      debugPrint('[VoiceCall] task ${result.taskId} result given up');
    }
    return delivered;
  }

  Future<bool> _sendResultOnce(VoiceTaskResult result) async {
    final Future<bool> Function(VoiceTaskResult)? override =
        _sendResultOverride;
    if (override != null) return override(result);
    final lk.Room? room = _room;
    final lk.LocalParticipant? local = room?.localParticipant;
    final String? agent = _agentIdentity;
    final bool agentHere =
        agent != null &&
        room != null &&
        room.remoteParticipants.values.any(
          (lk.RemoteParticipant p) => p.identity == agent,
        );
    if (local == null || !agentHere) return false;
    try {
      await local.performRpc(
        lk.PerformRpcParams(
          destinationIdentity: agent,
          method: VoiceProtocol.taskResultMethod,
          payload: VoiceProtocol.taskResultPayload(result),
        ),
      );
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '[VoiceCall] task ${result.taskId} result attempt failed: '
          '${e.runtimeType}',
        );
      }
      return false;
    }
  }

  void _armCallLimit(int gen, Duration limit) {
    _callLimitTimer?.cancel();
    _callLimitTimer = Timer(limit, () {
      if (gen != _generation || !isActive) return;
      if (kDebugMode) debugPrint('[VoiceCall] call limit reached, ending');
      unawaited(end());
    });
  }

  // ── Controls ──────────────────────────────────────────────────────────

  /// Mutes or unmutes the microphone. Before the room is up the choice is
  /// kept and applied once it connects.
  Future<void> setMicMuted(bool muted) async {
    if (_micMuted == muted) return;
    _micMuted = muted;
    notifyListeners();
    final lk.Room? room = _room;
    if (room == null || _phase != VoiceCallPhase.live) return;
    try {
      await room.localParticipant?.setMicrophoneEnabled(!muted);
    } on lk.LiveKitException catch (e) {
      if (kDebugMode) debugPrint('[VoiceCall] mute failed: ${e.runtimeType}');
      if (!muted &&
          (e is lk.TrackCreateException || e is lk.AudioSessionException)) {
        // The microphone cannot be reopened: a call without it is no call.
        await _finish(VoiceCallPhase.failed, error: _describe(e));
        return;
      }
      _micMuted = !muted;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) debugPrint('[VoiceCall] mute failed: ${e.runtimeType}');
      _micMuted = !muted;
      notifyListeners();
    }
  }

  /// Prefers the speaker ([on] true) or the earpiece. A headset always wins.
  /// Phones only ([canSwitchSpeaker]); elsewhere it does nothing.
  Future<void> setSpeakerOn(bool on) async {
    if (!canSwitchSpeaker || speakerOn == on) return;
    _speakerOn = on;
    notifyListeners();
    if (_phase != VoiceCallPhase.live) return;
    try {
      await lk.AudioManager.instance.setSpeakerOutputPreferred(on);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[VoiceCall] speaker switch failed: ${e.runtimeType}');
      }
    }
  }

  /// Hangs up. Returns the call's record, or null when nothing was said
  /// (no final turn and no card) or no call was running.
  Future<VoiceCallRecord?> end() {
    final Future<VoiceCallRecord?>? finishing = _finishing;
    if (finishing != null) return finishing;
    if (!isActive) return Future<VoiceCallRecord?>.value();
    return _finish(VoiceCallPhase.ended);
  }

  /// Clears a finished or failed call back to [VoiceCallPhase.idle] (the
  /// panel's dismiss). Does nothing while a call is active.
  void dismiss() {
    if (isActive || _phase == VoiceCallPhase.idle) return;
    _error = null;
    _setPhase(VoiceCallPhase.idle);
  }

  void _setPhase(VoiceCallPhase next) {
    _phase = next;
    notifyListeners();
    if (next != _lastEmittedPhase) {
      _lastEmittedPhase = next;
      _phases.add(next);
    }
  }

  // ── End ───────────────────────────────────────────────────────────────

  Future<VoiceCallRecord?> _finish(VoiceCallPhase target, {String? error}) {
    final Future<VoiceCallRecord?>? running = _finishing;
    if (running != null) return running;
    // Claimed before the teardown runs: its first notify may reach a
    // listener that calls end() again, which must join this one.
    final Completer<VoiceCallRecord?> done = Completer<VoiceCallRecord?>();
    _finishing = done.future;
    () async {
      try {
        done.complete(await _teardown(target, error));
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        _finishing = null;
      }
    }();
    return done.future;
  }

  Future<VoiceCallRecord?> _teardown(
    VoiceCallPhase target,
    String? error,
  ) async {
    _generation++;
    _setPhase(VoiceCallPhase.ending);

    _agentJoinTimer?.cancel();
    _agentJoinTimer = null;
    _agentLeftTimer?.cancel();
    _agentLeftTimer = null;
    _callLimitTimer?.cancel();
    _callLimitTimer = null;
    final StreamSubscription<VoiceTaskResult>? resultSub = _resultSub;
    _resultSub = null;
    await resultSub?.cancel();

    final lk.Room? room = _room;
    final lk.EventsListener<lk.RoomEvent>? listener = _roomListener;
    _room = null;
    _roomListener = null;
    if (room != null) {
      for (final String method in VoiceProtocol.appMethods) {
        room.unregisterRpcMethod(method);
      }
      room.unregisterTextStreamHandler(VoiceTranscriptionAttributes.topic);
      await _quietly(() async => listener?.dispose());
      await _quietly(room.disconnect);
      await _quietly(room.dispose);
    }

    final DateTime endedAt = DateTime.now();
    final List<VoiceTurn> recordTurns = _transcript.recordTurns();
    final List<VoiceCard> recordCards = List<VoiceCard>.of(_cardList);
    final String? chatId = _chatId;
    final VoiceCallMode? mode = _mode;
    final DateTime? startedAt = _startedAt;
    VoiceCallRecord? record;
    if (chatId != null &&
        mode != null &&
        startedAt != null &&
        (recordTurns.any((VoiceTurn t) => t.isFinal) ||
            recordCards.isNotEmpty)) {
      record = VoiceCallRecord(
        chatId: chatId,
        mode: mode,
        startedAt: startedAt,
        endedAt: endedAt,
        turns: recordTurns,
        cards: recordCards,
      );
      try {
        await VoiceCallStore.save(record);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[VoiceCall] record not saved: ${e.runtimeType}');
        }
      }
    }

    _tasks.reset(null);
    _agentIdentity = null;
    _tools.clear();
    _runningTools = const <VoiceToolActivity>[];
    _micMuted = false;
    _agentSpeaking = false;
    _agentThinking = false;
    _agentPresent = false;
    _error = target == VoiceCallPhase.failed
        ? (error ?? 'The call failed')
        : null;
    _setPhase(target);
    if (kDebugMode) {
      debugPrint(
        '[VoiceCall] ${target.name}: ${recordTurns.length} turns, '
        'saved=${record != null}',
      );
    }
    if (record != null) _ended.add(record);
    return record;
  }

  static Future<void> _quietly(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (kDebugMode) debugPrint('[VoiceCall] teardown: ${e.runtimeType}');
    }
  }

  static String _describe(Object e) {
    if (e is VoiceCallException) return e.message;
    if (e is lk.TrackCreateException) return 'Could not open the microphone';
    if (e is lk.AudioSessionException) return 'Could not open the audio device';
    // A LiveKit or socket error can name the server; show a plain line.
    return 'Could not connect the call';
  }

  // ── Tests ─────────────────────────────────────────────────────────────

  /// Puts the controller into a given state without a room, so widget tests
  /// can draw the panel.
  @visibleForTesting
  void debugSetState({
    required VoiceCallPhase phase,
    String? chatId,
    VoiceCallMode? mode,
    List<VoiceTurn> turns = const <VoiceTurn>[],
    List<VoiceCard> cards = const <VoiceCard>[],
    List<VoiceToolActivity> runningTools = const <VoiceToolActivity>[],
    bool micMuted = false,
    bool agentSpeaking = false,
    bool agentThinking = false,
    bool agentPresent = true,
    String? agentName,
    String? error,
    DateTime? startedAt,
    VoiceTaskDelegate? delegate,
  }) {
    _tasks.reset(delegate);
    _listenForResults(delegate, _generation);
    _phase = phase;
    _chatId = chatId;
    _mode = mode;
    _turns = List<VoiceTurn>.unmodifiable(turns);
    _cards = List<VoiceCard>.unmodifiable(cards);
    _runningTools = List<VoiceToolActivity>.unmodifiable(runningTools);
    _micMuted = micMuted;
    _agentSpeaking = agentSpeaking;
    _agentThinking = agentThinking;
    _agentPresent = agentPresent;
    _agentName = agentName;
    _error = error;
    _startedAt = startedAt;
    notifyListeners();
  }

  /// Runs the `chuk.delegate` handler the room registers.
  @visibleForTesting
  Future<String> debugHandleDelegateRpc(String payload) =>
      _handleDelegateRpc(payload);

  /// Runs the `get_location` handler the room registers.
  @visibleForTesting
  Future<String> debugHandleLocationRpc() => _location.answer();

  /// Arms the call limit with [limit] instead of [maxCallDuration].
  @visibleForTesting
  void debugArmCallLimit(Duration limit) => _armCallLimit(_generation, limit);

  /// The task ids started through the current delegate with no result yet.
  @visibleForTesting
  Set<String> get debugPendingTasks => _tasks.pending;
}
