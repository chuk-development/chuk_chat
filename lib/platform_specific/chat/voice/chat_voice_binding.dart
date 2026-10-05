// lib/platform_specific/chat/voice/chat_voice_binding.dart
//
// The glue between one chat screen and the app-wide voice call:
//
//  * starts and ends a call for the chat on screen, with its title, the
//    coworker's name and the last messages as context;
//  * hands the call a delegate that sends spoken tasks through the screen's
//    own send path (voice_task_delegates.dart);
//  * keeps the chat's call records for the message list (display only).
//
// A chat screen creates one binding ONLY when [voiceCallUiEnabled] is true.
// With the flag off nothing here is built, listened to or registered.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_call_context.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_task_delegates.dart';
import 'package:chuk_chat/platform_specific/chat/voice/voice_turn_queue.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/voice/voice_call_controller.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_call_service.dart';
import 'package:chuk_chat/voice/voice_call_store.dart';

/// Whether this build shows the voice call at all: the build flag and a
/// configured token server. Everything in this folder is behind it.
bool get voiceCallUiEnabled => VoiceCallService.isAvailable;

/// The mode a call for [chatId] runs in.
VoiceCallMode voiceCallModeFor(String chatId) =>
    ChatOrigin.isAgentsThread(chatId)
    ? VoiceCallMode.agents
    : VoiceCallMode.chat;

/// The stored title of [chatId], or null.
String? storedChatTitle(String chatId) {
  final chat = ChatStorageService.getChatById(chatId);
  if (chat == null) return null;
  final String? name = chat.customName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final String? title = chat.title?.trim();
  return (title == null || title.isEmpty) ? null : title;
}

/// The stored messages of [chatId] as chat rows, for a call started from a
/// page that has no chat screen open (the coworker profile).
List<Map<String, String>> storedChatRows(String chatId) {
  final chat = ChatStorageService.getChatById(chatId);
  if (chat == null || !chat.isFullyLoaded) return const <Map<String, String>>[];
  return <Map<String, String>>[
    for (final ChatMessage m in chat.messages)
      <String, String>{
        'sender': m.role == 'user' ? 'user' : 'ai',
        'text': m.text,
      },
  ];
}

class ChatVoiceBinding {
  ChatVoiceBinding({
    required this.currentChatId,
    required this.isAgentsScreen,
    required this.messages,
    required bool Function() isBusy,
    required VoiceTurnSend send,
    required this.onRecordsChanged,
    this.agentName,
    this.ensureChatId,
    this.discardChat,
    bool Function()? isOffline,
    VoiceCallController? controller,
  }) : controller = controller ?? VoiceCallController.instance {
    _queue = VoiceTurnQueue(
      send: send,
      isBusy: isBusy,
      currentChatId: currentChatId,
      isOffline: isOffline ?? () => !NetworkStatusService.isOnline,
      // A host task can run for a long time; a hosted turn cannot.
      maxWait: Duration(minutes: isAgentsScreen ? 30 : 10),
      turnTimeout: Duration(minutes: isAgentsScreen ? 60 : 15),
    );
    _endedSub = this.controller.onCallEnded.listen(_onCallEnded);
    this.controller.addListener(_onController);
    ChatVoiceSessions.instance._add(this);
  }

  final VoiceCallController controller;

  /// The chat on screen right now; null for a new chat that has no id yet.
  final String? Function() currentChatId;

  /// This screen is the Agents thread view (one per app).
  final bool isAgentsScreen;

  /// The rows of the chat on screen, for the call context.
  final List<Map<String, String>> Function() messages;

  /// Called when the records of the chat on screen changed.
  final VoidCallback onRecordsChanged;

  /// The coworker this screen talks to, when the screen knows it (the
  /// desktop Agents thread is handed the coworker's name). A call started
  /// without a name uses it before it falls back to the thread title.
  final String? Function()? agentName;

  /// Gives a new chat (no id yet) its id, so a call can start before the
  /// first message. The screen assigns the id to itself, the way its first
  /// send does, and returns it; null when it cannot.
  final Future<String?> Function()? ensureChatId;

  /// Gives back a chat id that [ensureChatId] made for a call, once that
  /// call is over and nothing landed in the chat (no message, no call
  /// record), so no empty chat is left behind.
  final Future<void> Function(String chatId)? discardChat;

  late final VoiceTurnQueue _queue;
  StreamSubscription<VoiceCallRecord>? _endedSub;
  VoiceTurnDelegate? _delegate;
  String? _delegateChatId;
  bool _starting = false;
  bool _disposed = false;

  /// [ensureChatId] runs: one creation at a time.
  bool _creating = false;

  /// The id [ensureChatId] made for a call, until that call is over.
  String? _onDemandChatId;

  /// The call in [_onDemandChatId] saved a record (something was said).
  bool _onDemandRecorded = false;
  bool _onDemandSettling = false;

  String? _recordsChatId;
  List<VoiceCallRecord> _records = const <VoiceCallRecord>[];
  int _loadGen = 0;

  // ── Call state ──────────────────────────────────────────────────────

  /// True while a call for [chatId] holds the room.
  bool isLiveFor(String? chatId) =>
      chatId != null && controller.chatId == chatId && controller.isActive;

  /// Whether the call panel belongs on screen for [chatId]: its call is
  /// running, or it just failed and says why.
  bool showsPanelFor(String? chatId) =>
      chatId != null &&
      controller.chatId == chatId &&
      (controller.isActive || controller.phase == VoiceCallPhase.failed);

  /// Starts a call for the chat on screen, or hangs up the one running there.
  /// A new chat with no id yet gets one first ([ensureChatId]).
  Future<void> toggleCall({String? agentName}) async {
    final String? chatId = currentChatId();
    if (chatId != null && chatId.isNotEmpty && isLiveFor(chatId)) {
      await controller.end();
      return;
    }
    await startCall(agentName: agentName);
  }

  /// Starts a call for the chat on screen.
  ///
  /// [callId], [callReason] and [initiatedByAgent] describe a call the agent
  /// started and the user accepted (spec §6.3, lib/voice/incoming/); a call
  /// the user starts leaves them out.
  ///
  /// A new chat with no id yet gets one from [ensureChatId] first. While
  /// that runs, a second start (a double tap) is dropped.
  Future<void> startCall({
    String? agentName,
    String? callId,
    String? callReason,
    bool initiatedByAgent = false,
  }) async {
    if (_disposed || _creating) return;
    final String? onScreen = currentChatId();
    final bool needsChat = onScreen == null || onScreen.isEmpty;
    if (needsChat && ensureChatId == null) return;
    _starting = true;
    try {
      final String? chatId = needsChat ? await _createChat() : onScreen;
      if (_disposed || chatId == null) return;
      final VoiceCallMode mode = voiceCallModeFor(chatId);
      // Hang up first, so the old call's teardown cannot take the new
      // delegate down with it.
      if (controller.isActive) await controller.end();
      _endCallTasks();
      final VoiceTurnDelegate delegate = _adopt(chatId, mode);
      final String? title = storedChatTitle(chatId);
      final String? name = mode == VoiceCallMode.agents
          ? (_nonEmpty(agentName) ?? _nonEmpty(this.agentName?.call()) ?? title)
          : null;
      debugOnVoiceCallStart?.call((
        chatId: chatId,
        mode: mode,
        agentName: name,
        callId: callId,
        callReason: callReason,
        initiatedByAgent: initiatedByAgent,
        hasDelegate: true,
      ));
      await controller.start(
        chatId: chatId,
        mode: mode,
        chatTitle: title,
        agentName: name,
        context: buildVoiceCallContext(messages()),
        delegate: delegate,
        callId: callId,
        callReason: callReason,
        initiatedByAgent: initiatedByAgent,
      );
    } finally {
      _starting = false;
      _onController();
    }
  }

  /// Runs [ensureChatId] once and remembers the id it made, so the chat can
  /// be given back if the call leaves it empty.
  Future<String?> _createChat() async {
    _creating = true;
    try {
      final String? id = (await ensureChatId!())?.trim();
      if (id == null || id.isEmpty) return null;
      _onDemandChatId = id;
      _onDemandRecorded = false;
      return id;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ChatVoice] chat not created: ${e.runtimeType}');
      }
      return null;
    } finally {
      _creating = false;
    }
  }

  /// The call in the chat [ensureChatId] made is over (its panel is gone):
  /// give the chat back when it is still empty. The ended call's record, if
  /// any, arrives on its stream just after the phase change, so the check
  /// waits one turn of the event loop for it.
  void _settleOnDemandChat() {
    final String? id = _onDemandChatId;
    if (_disposed || id == null || _onDemandSettling || showsPanelFor(id)) {
      return;
    }
    _onDemandSettling = true;
    unawaited(
      Future<void>.delayed(Duration.zero, () {
        _onDemandSettling = false;
        if (_disposed || _onDemandChatId != id || showsPanelFor(id)) return;
        _onDemandChatId = null;
        final bool recorded = _onDemandRecorded;
        _onDemandRecorded = false;
        final Future<void> Function(String chatId)? discard = discardChat;
        if (discard == null || recorded) return;
        if (currentChatId() != id || messages().isNotEmpty) return;
        unawaited(
          discard(id).catchError((Object e) {
            if (kDebugMode) {
              debugPrint(
                '[ChatVoice] empty chat not removed: ${e.runtimeType}',
              );
            }
          }),
        );
      }),
    );
  }

  /// A fresh delegate for a call in [chatId], held as the current one. Each
  /// task carries its call (the delegate) as its tag, so a hang-up cancels
  /// exactly the tasks of that call that have not started.
  VoiceTurnDelegate _adopt(String chatId, VoiceCallMode mode) {
    late final VoiceTurnDelegate delegate;
    Future<VoiceTurnOutcome> send(String text) =>
        _queue.enqueue(chatId, text, tag: delegate);
    delegate = mode == VoiceCallMode.agents
        ? AgentsVoiceDelegate(send)
        : ChatVoiceDelegate(send);
    _delegate = delegate;
    _delegateChatId = chatId;
    return delegate;
  }

  /// Test seam: holds a delegate for the chat on screen as if its call had
  /// started, without a room.
  @visibleForTesting
  VoiceTurnDelegate debugAdoptDelegate() {
    final String chatId = currentChatId()!;
    return _adopt(chatId, voiceCallModeFor(chatId));
  }

  static String? _nonEmpty(String? s) {
    final String? t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  void _onController() {
    if (_starting) return;
    _settleOnDemandChat();
    if (_delegate == null) return;
    final bool ours =
        controller.chatId == _delegateChatId && controller.isActive;
    if (!ours) _endCallTasks();
  }

  /// The call of [_delegate] is over (hung up, dropped, failed, or replaced
  /// by another call). Its tasks that have not started are cancelled as
  /// failed; tasks already running finish in the chat. The controller has
  /// already let go of the delegate, so it is only closed.
  void _endCallTasks() {
    final VoiceTurnDelegate? old = _delegate;
    _delegate = null;
    _delegateChatId = null;
    if (old == null) return;
    _queue.cancelPending(old, kVoiceTaskCallEnded);
    unawaited(old.close());
  }

  // ── Turn hooks (called by the chat screen) ──────────────────────────

  /// The screen finalized assistant row [index] of [chatId] with [text].
  void completeTurn(String? chatId, int index, String text) {
    if (chatId == null) return;
    _queue.complete(chatId, index, text);
  }

  /// The turn at row [index] of [chatId] was torn down without an answer.
  void failTurn(String? chatId, int index) {
    if (chatId == null) return;
    _queue.fail(chatId, index, 'The answer was interrupted.');
  }

  // ── Records (display only) ──────────────────────────────────────────

  /// The call records of [chatId], oldest first. The first ask for a chat
  /// starts the load and answers empty; [onRecordsChanged] fires when the
  /// records arrive.
  List<VoiceCallRecord> recordsFor(String? chatId) {
    if (chatId == null || chatId.isEmpty) return const <VoiceCallRecord>[];
    if (_recordsChatId == chatId) return _records;
    _recordsChatId = chatId;
    _records = const <VoiceCallRecord>[];
    final int gen = ++_loadGen;
    unawaited(_load(chatId, gen));
    return _records;
  }

  Future<void> _load(String chatId, int gen) async {
    List<VoiceCallRecord> loaded;
    try {
      loaded = await VoiceCallStore.forChat(chatId);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ChatVoice] records not loaded: ${e.runtimeType}');
      }
      return;
    }
    if (_disposed || gen != _loadGen || _recordsChatId != chatId) return;
    if (loaded.isEmpty && _records.isEmpty) return;
    _records = _merge(_records, loaded);
    onRecordsChanged();
  }

  void _onCallEnded(VoiceCallRecord record) {
    if (_disposed) return;
    if (record.chatId == _onDemandChatId) _onDemandRecorded = true;
    if (record.chatId != _recordsChatId) return;
    _records = _merge(_records, <VoiceCallRecord>[record]);
    onRecordsChanged();
  }

  static List<VoiceCallRecord> _merge(
    List<VoiceCallRecord> a,
    List<VoiceCallRecord> b,
  ) {
    final Map<int, VoiceCallRecord> byStart = <int, VoiceCallRecord>{
      for (final VoiceCallRecord r in a) r.startedAt.microsecondsSinceEpoch: r,
      for (final VoiceCallRecord r in b) r.startedAt.microsecondsSinceEpoch: r,
    };
    return byStart.values.toList()..sort(
      (VoiceCallRecord x, VoiceCallRecord y) =>
          x.startedAt.compareTo(y.startedAt),
    );
  }

  /// The screen goes away. A call that is still running keeps going, but
  /// without this screen's delegate: every open task is reported failed
  /// while the result stream is still open, the controller lets go of the
  /// delegate (a later task gets an error, not silence), and only then is
  /// the delegate closed.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.removeListener(_onController);
    unawaited(_endedSub?.cancel());
    _endedSub = null;
    final VoiceTurnDelegate? delegate = _delegate;
    _delegate = null;
    _delegateChatId = null;
    if (delegate != null) {
      delegate.failOpenTasks(kVoiceTaskChatClosed);
      controller.detachDelegate(delegate);
    }
    _queue.dispose();
    if (delegate != null) unawaited(delegate.close());
    ChatVoiceSessions.instance._remove(this);
  }
}

/// The chat screens that can hold a call, so a header drawn outside a
/// screen (the Agents thread header, the phone chat chrome, the coworker
/// profile) can reach the screen that owns the chat.
class ChatVoiceSessions extends ChangeNotifier {
  ChatVoiceSessions._();

  static final ChatVoiceSessions instance = ChatVoiceSessions._();

  final List<ChatVoiceBinding> _bindings = <ChatVoiceBinding>[];

  void _add(ChatVoiceBinding binding) {
    _bindings.add(binding);
    notifyListeners();
  }

  void _remove(ChatVoiceBinding binding) {
    if (_bindings.remove(binding)) notifyListeners();
  }

  /// The Agents thread screen, or the normal chat screen. The newest one
  /// when a relayout briefly mounts two.
  ChatVoiceBinding? forRole({required bool agents}) {
    for (int i = _bindings.length - 1; i >= 0; i--) {
      if (_bindings[i].isAgentsScreen == agents) return _bindings[i];
    }
    return null;
  }

  /// The screen that has [chatId] open, if any.
  ChatVoiceBinding? forChat(String chatId) {
    for (int i = _bindings.length - 1; i >= 0; i--) {
      if (_bindings[i].currentChatId() == chatId) return _bindings[i];
    }
    return null;
  }
}

/// The thread a call with [agent] runs in: the one open on the Agents
/// screen when it is one of the coworker's, else its first (the permanent
/// session). Null when it has none.
String? voiceThreadKeyFor(AgentsAgent agent) {
  if (agent.threads.isEmpty) return null;
  final String? open = ChatVoiceSessions.instance
      .forRole(agents: true)
      ?.currentChatId();
  for (final AgentsThreadInfo t in agent.threads) {
    if (t.key == open) return t.key;
  }
  return agent.threads.first.key;
}

/// Starts a call with [agent] from a page that is not its thread (the
/// coworker profile, the phone "more" sheet). See
/// [startAgentsThreadVoiceCall].
Future<void> startAgentVoiceCall(
  AgentsAgent agent, {
  Duration waitForThread = Duration.zero,
}) async {
  final String? key = voiceThreadKeyFor(agent);
  if (key == null) return;
  await startAgentsThreadVoiceCall(
    threadKey: key,
    agentName: agent.name,
    waitForThread: waitForThread,
  );
}

/// Starts a call for an Agents thread from a page that is not the thread.
/// When the thread is open on its screen (or opens within [waitForThread],
/// for a caller that has just navigated to it) the call gets the full task
/// delegate; otherwise it is a voice call with the stored context and no
/// delegate.
///
/// [callId], [callReason] and [initiatedByAgent] go through to
/// [ChatVoiceBinding.startCall] (or the plain start) for a call the agent
/// started (lib/voice/incoming/). [enabled] is a test seam and defaults to
/// [voiceCallUiEnabled].
Future<void> startAgentsThreadVoiceCall({
  required String threadKey,
  String? agentName,
  Duration waitForThread = Duration.zero,
  VoiceCallController? controller,
  String? callId,
  String? callReason,
  bool initiatedByAgent = false,
  bool? enabled,
}) async {
  if (!(enabled ?? voiceCallUiEnabled) || threadKey.isEmpty) return;
  ChatVoiceBinding? binding = ChatVoiceSessions.instance.forChat(threadKey);
  final DateTime until = DateTime.now().add(waitForThread);
  while (binding == null && DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    binding = ChatVoiceSessions.instance.forChat(threadKey);
  }
  if (binding != null) {
    await binding.startCall(
      agentName: agentName,
      callId: callId,
      callReason: callReason,
      initiatedByAgent: initiatedByAgent,
    );
    return;
  }
  final VoiceCallController c = controller ?? VoiceCallController.instance;
  final String? title = storedChatTitle(threadKey);
  debugOnVoiceCallStart?.call((
    chatId: threadKey,
    mode: VoiceCallMode.agents,
    agentName: agentName ?? title,
    callId: callId,
    callReason: callReason,
    initiatedByAgent: initiatedByAgent,
    hasDelegate: false,
  ));
  await c.start(
    chatId: threadKey,
    mode: VoiceCallMode.agents,
    chatTitle: title,
    agentName: agentName ?? title,
    context: buildVoiceCallContext(storedChatRows(threadKey)),
    callId: callId,
    callReason: callReason,
    initiatedByAgent: initiatedByAgent,
  );
}

/// What a start from this file hands to `VoiceCallController.start`, for a
/// test to read: the agent-call fields, and whether the chat screen's task
/// delegate rides along.
typedef VoiceCallStartProbe = ({
  String chatId,
  VoiceCallMode mode,
  String? agentName,
  String? callId,
  String? callReason,
  bool initiatedByAgent,
  bool hasDelegate,
});

/// Test seam: sees every [VoiceCallStartProbe] just before the start.
@visibleForTesting
void Function(VoiceCallStartProbe probe)? debugOnVoiceCallStart;
