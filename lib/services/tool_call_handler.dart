import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart' show NativeToolCall;
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/agents/agents_tool_call_handler.dart';
import 'package:chuk_chat/services/per_model_system_prompt_service.dart';
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/skills/skills_catalog_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/workspace_storage_service.dart';
import 'package:chuk_chat/services/tool_enforcer.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/services/tool_pairing_validator.dart';
import 'package:chuk_chat/services/tool_prompt_builder.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_connector.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_tool_bridge.dart';
import 'package:chuk_chat/services/mcp/mcp_availability.dart';
import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/mcp/mcp_sync_service.dart';
import 'package:chuk_chat/services/mcp/mcp_tool_bridge.dart';
import 'package:chuk_chat/services/tool_registry.dart';
import 'package:chuk_chat/tool_handlers/platform_tools.dart' as platform_tools;
import 'package:chuk_chat/tool_handlers/notes_tools.dart';
import 'package:chuk_chat/utils/tool_parser.dart';
import 'package:chuk_chat/utils/tool_sanitizer.dart';

/// Tools that only read. A round made up entirely of these can run its
/// calls at the same time — none of them changes state, so the order
/// they finish in does not matter.
const Set<String> _readOnlyToolNames = <String>{
  'web_search',
  'web_crawl',
  'search_places',
  'search_restaurants',
  'geocode',
  'get_route',
  'road_closures',
  'weather',
  'search_chats',
  'get_time',
  'calculate',
  'find_tools',
  'view_chat_images',
};

/// Read-only lookups whose result does not change within one turn: the same
/// call with the same arguments returns the same data. A repeat of such a
/// call is answered from the result the turn already holds instead of being
/// run again. `get_time` is left out (the time moves on) and `find_tools`
/// too (its result updates the discovered tool set).
@visibleForTesting
const Set<String> repeatableLookupToolNames = <String>{
  'web_search',
  'web_crawl',
  'search_places',
  'search_restaurants',
  'geocode',
  'get_route',
  'road_closures',
  'weather',
  'search_chats',
  'calculate',
  'view_chat_images',
};

/// Prefix of a tool result that was answered from an identical earlier call
/// in the same turn instead of being run again.
@visibleForTesting
const String kRepeatedToolCallNote =
    '[REPEATED CALL] This exact call already ran in this turn. The result '
    'below is the one it returned then. Do not call it again; answer the user '
    'from it.';

/// Added to [kRepeatedToolCallNote] on the round that closes the tools.
@visibleForTesting
const String kToolsClosedNote =
    'Tools are now closed for this turn. Write the final answer for the user '
    'from the results you have.';

/// Most tool rounds one user turn may run. Every round re-sends the whole
/// history, so the cost of a turn grows with the square of its rounds. On
/// 2026-09-23 a weather question ran 24 rounds (the old cap) and re-sent
/// about 400 kB of tool results on each of them. Real turns in the owner's
/// 939 chats need at most 16 rounds.
@visibleForTesting
const int kMaxToolRoundsPerTurn = 16;

/// Sent as the user turn of the forced final pass. When the round limit is
/// reached (or the tools closed because the model repeated itself), the turn
/// does not end with an apology: one more pass goes out with no tool
/// definitions and this instruction, so the model answers from what it has.
/// The api_server sends the same text (`chat/tool_history.py`).
@visibleForTesting
const String kForcedFinalAnswerNote =
    'The tool limit for this turn is reached. Tools are now closed. '
    'Write the final answer for the user now, from the tool results you '
    'already have. Do not call any tool.';

/// Forced final passes one turn may send before it ends with what it has.
/// The second one only runs when the model ignored the first and asked for
/// tools again.
const int _maxForcedFinalPasses = 2;

/// Tool results are capped ONCE, when they first go into the history
/// ([capToolResultForModel]: head + tail in code points). The capped text is
/// what every later pass re-sends, byte for byte. The loop used to shorten
/// older rounds again once a newer round existed, which changed the history
/// between passes and made the provider's prompt cache miss on everything
/// after the first shortened result.

/// A key that is equal for two calls with the same name and the same
/// arguments, whatever the order of the argument keys.
@visibleForTesting
String toolCallIdentityKey(String name, Map<String, dynamic> arguments) =>
    '$name ${jsonEncode(_canonicalJson(arguments))}';

Object? _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalJson).toList();
  return value;
}

class ToolLoopSession {
  ToolLoopSession({
    required this.latestUserMessage,
    required this.history,
    required this.accessToken,
    required this.enforcer,
    required this.toolCallingEnabled,
    required this.discoveryMode,
    this.baseSystemPrompt,
    this.discoveryContextKey,
    this.modelId,
    this.skipIdentity = false,
    this.nativeToolCalling = false,
    this.userSentAt,
    this.promptSnapshot,
    this.promptEffective,
    this.toolHistory = true,
  }) : turnHistoryStart = history.length,
       firstPassMessage = latestUserMessage;

  String latestUserMessage;

  /// The user message of this turn as the first pass must send it: with its
  /// `[Sent: …]` line and any tagged notes (prompt_context.dart). Set by
  /// [ToolCallHandler.buildInitialSystemPrompt]; the same text goes into the
  /// history on the next pass, so the two requests share the prefix.
  String firstPassMessage;

  /// Length of [history] when the turn started. Entries from here on were
  /// added by this turn's tool loop.
  final int turnHistoryStart;

  /// `sentAt` of the stored user message this turn sends. The `[Sent: …]`
  /// line is made from it, and the turn's [turnContext] is stored under it.
  final String? userSentAt;

  /// The chat's frozen prompt inputs, from the history (null for a chat that
  /// never stored one; the first request then takes it).
  PromptState? promptSnapshot;

  /// The prompt inputs after every note the history already holds.
  final PromptState? promptEffective;

  /// What this turn adds to its user message's `modelContext`.
  final TurnPromptContext turnContext = TurnPromptContext();

  /// Whether the chat replays earlier turns' tool rounds (from the history;
  /// stored in the snapshot when this turn takes it).
  final bool toolHistory;

  /// Index in [history] of this turn's own user message, once a pass put it
  /// there; null before. Later passes put the turn's images into this entry
  /// ([ToolLoopStep.withTurnImages]), and the stored transcript starts
  /// after it.
  int? turnUserIndex;

  /// The system prompt of this chat, built once per turn and re-sent on
  /// every pass, byte for byte.
  String? frozenSystemPrompt;

  bool _contextPrepared = false;
  final List<Map<String, dynamic>> history;
  final String accessToken;
  final ToolEnforcer enforcer;
  final bool toolCallingEnabled;
  final bool discoveryMode;
  final String? baseSystemPrompt;
  final String? discoveryContextKey;

  /// Currently-selected model id. When set, the per-model system prompt
  /// configuration (if any) is merged into the final system prompt.
  final String? modelId;

  /// When true, the identity section (Soul/User/Memory) is not injected
  /// into the system prompt. Used for assistants with memory disabled.
  final bool skipIdentity;

  /// When true, tools are exposed to the model natively (the request carries a
  /// `tools[]` array and the provider streams structured `tool_calls`), so the
  /// system prompt omits the prompt-based `<tool_call>` protocol and per-tool
  /// prose. When false, the legacy prompt-based scheme applies (fallback).
  final bool nativeToolCalling;

  final List<Map<String, dynamic>> discoveredTools = [];
  final Set<String> discoveredToolNames = {};

  /// Skills activated via the `skill` tool, oldest first. A body is sent
  /// once, as a `<skill_content>` user message after the round that loaded
  /// it, never in the system prompt. Ordered (not a Set) so eviction can drop
  /// the least-recently activated one.
  final List<String> activeSkillNames = [];

  /// Skill bodies loaded in the round being run, appended to the history
  /// after its tool results.
  final List<SkillContent> pendingSkillContents = [];

  final List<ToolCall> toolCalls = [];

  /// Content blocks produced as side-effects of tool calls in this loop
  /// (e.g. a places lookup emits a `<map>` block). These are
  /// surfaced to the streaming handler via `ToolLoopResult.producedBlocks`,
  /// which slices the new items off this list each round.
  final List<ContentBlock> producedBlocks = [];

  int emptyFinalRecoveryAttempts = 0;
  int malformedToolProtocolRecoveryAttempts = 0;
  int truncatedCompletionRecoveryAttempts = 0;
  int deferredActionRecoveryAttempts = 0;
  int nonFinalTurnRecoveryAttempts = 0;
  int factCheckRecoveryAttempts = 0;

  /// Rounds with at least one call that repeated a lookup this turn already
  /// held. The first is answered from the held results with a note; a second
  /// means the model ignored the note, and the tools close (see
  /// [toolsClosed]). A round that mixes a repeat with a new call counts too,
  /// or a model could add one new call per round and never be stopped.
  int repeatedLookupRounds = 0;

  /// Set when the model kept repeating lookups it already had. The next pass
  /// goes out with no tool definitions, so the model can only answer.
  bool toolsClosed = false;

  /// Set by the stream driver when its own pass budget is nearly used up.
  /// Acts like [toolsClosed]: the next tool request gets the forced final
  /// pass instead of running.
  bool finalAnswerRequested = false;

  /// Forced final passes sent this turn (see [kForcedFinalAnswerNote]).
  int forcedFinalPasses = 0;

  /// True once the model may not call tools any more this turn.
  bool get toolsShut => toolsClosed || finalAnswerRequested;

  /// The tool-grounded candidate answer captured just before a fact-check
  /// ([VERIFY]) pass, plus its reasoning. The verify pass keeps this as the
  /// final answer unless it emits an explicit `[CORRECTED]` replacement — so a
  /// model that merely acknowledges the check (instead of re-emitting the
  /// answer) can never blank out a valid grounded answer. Consumed (set back to
  /// null) when the fact-check resolves.
  String? factCheckCandidate;
  String factCheckCandidateReasoning = '';
}

class ToolLoopStep {
  const ToolLoopStep({
    required this.message,
    required this.history,
    required this.systemPrompt,
    this.turnUserIndex,
    this.passImages,
  });

  final String message;
  final List<Map<String, dynamic>> history;
  final String? systemPrompt;

  /// Index in [history] of the turn's own user message (null when no pass
  /// put it there yet).
  final int? turnUserIndex;

  /// The images to send with [message]. Only set by [withTurnImages].
  final List<String>? passImages;

  /// This step with the turn's images ([images], storage paths or data
  /// URLs) in the turn's own history entry, in their order, and none sent
  /// with [message]. Sent with [message], the images landed on the tool
  /// results (prompt-based mode) or on an empty user message (native mode),
  /// and the turn's entry differed from the first pass's. When the turn's
  /// entry is not in [history], the images go with [message] as before.
  ToolLoopStep withTurnImages(List<String>? images) {
    if (images == null || images.isEmpty) return this;
    final index = turnUserIndex;
    if (index == null || index < 0 || index >= history.length) {
      return ToolLoopStep(
        message: message,
        history: history,
        systemPrompt: systemPrompt,
        turnUserIndex: turnUserIndex,
        passImages: images,
      );
    }
    final entry = history[index];
    final content = entry['content'];
    final out = List<Map<String, dynamic>>.of(history);
    out[index] = <String, dynamic>{
      ...entry,
      'content': userContentWithImages(
        content is String ? content : '',
        images,
      ),
    };
    return ToolLoopStep(
      message: message,
      history: out,
      systemPrompt: systemPrompt,
      turnUserIndex: index,
    );
  }
}

/// One segment in the model's interleaved output for a single round.
///
/// When the model emits text, then a tool_call, then more text, then
/// another tool_call (and so on), the renderer needs the original order
/// to display intro/outro text around each tool. A segment is either
/// a text chunk or a single tool call.
class RoundSegment {
  const RoundSegment._({this.text, this.toolCall});

  factory RoundSegment.text(String text) => RoundSegment._(text: text);
  factory RoundSegment.toolCall(ToolCall tc) => RoundSegment._(toolCall: tc);

  final String? text;
  final ToolCall? toolCall;

  bool get isText => text != null;
  bool get isToolCall => toolCall != null;
}

class ToolLoopResult {
  const ToolLoopResult._({
    required this.shouldContinue,
    this.nextStep,
    this.finalContent,
    this.finalReasoning,
    this.interimContent,
    this.interimBeforeToolCalls = false,
    this.toolCalls = const [],
    this.interleavedSegments = const [],
    this.producedBlocks = const [],
  });

  factory ToolLoopResult.continueWith({
    required ToolLoopStep nextStep,
    String? interimContent,
    bool interimBeforeToolCalls = false,
    List<ToolCall> toolCalls = const [],
    List<RoundSegment> interleavedSegments = const [],
    List<ContentBlock> producedBlocks = const [],
  }) {
    return ToolLoopResult._(
      shouldContinue: true,
      nextStep: nextStep,
      interimContent: interimContent,
      interimBeforeToolCalls: interimBeforeToolCalls,
      toolCalls: toolCalls,
      interleavedSegments: interleavedSegments,
      producedBlocks: producedBlocks,
    );
  }

  factory ToolLoopResult.finalAnswer({
    required String content,
    required String reasoning,
    List<ToolCall> toolCalls = const [],
    List<ContentBlock> producedBlocks = const [],
  }) {
    return ToolLoopResult._(
      shouldContinue: false,
      finalContent: content,
      finalReasoning: reasoning,
      toolCalls: toolCalls,
      producedBlocks: producedBlocks,
    );
  }

  final bool shouldContinue;
  final ToolLoopStep? nextStep;
  final String? finalContent;
  final String? finalReasoning;
  final String? interimContent;
  final bool interimBeforeToolCalls;
  final List<ToolCall> toolCalls;

  /// Ordered list of text/tool segments produced this round. Empty when the
  /// round was not interleaved (no text between tool calls). When non-empty,
  /// renderers should prefer this over [interimContent] + [toolCalls] to
  /// preserve the model's original ordering.
  final List<RoundSegment> interleavedSegments;

  /// New content blocks produced as side-effects of tool calls during this
  /// round (e.g. a places lookup -> `<map>` block). Streaming
  /// handlers should append these to the assistant message's content blocks
  /// so the user sees the artifact inline.
  final List<ContentBlock> producedBlocks;
}

/// Provider/tool-loop hints extracted from stream metadata.
///
/// When available, this enables Anthropic/OpenAI-style control flow:
/// - `tool_use` / `tool_calls` => continue tool loop.
/// - `end_turn` / `stop` => finalize answer.
/// - `max_tokens` / `length` => request continuation pass.
///
/// If the backend does not provide these fields, fall back to local parsing.
class ToolTurnSignals {
  const ToolTurnSignals._({this.stopReason, this.finishReason, this.rawMeta});

  final String? stopReason;
  final String? finishReason;
  final Map<String, dynamic>? rawMeta;

  static const Set<String> _toolUseReasons = <String>{
    'tool_use',
    'tool_calls',
    'function_call',
    'function_calls',
  };

  static const Set<String> _finalReasons = <String>{
    'stop',
    'end_turn',
    'stop_sequence',
    'eos',
  };

  static const Set<String> _truncatedReasons = <String>{'max_tokens', 'length'};

  bool get indicatesToolUse =>
      _toolUseReasons.contains(stopReason) ||
      _toolUseReasons.contains(finishReason);

  bool get indicatesFinalStop =>
      _finalReasons.contains(stopReason) ||
      _finalReasons.contains(finishReason);

  bool get indicatesTruncated =>
      _truncatedReasons.contains(stopReason) ||
      _truncatedReasons.contains(finishReason);

  static ToolTurnSignals fromMeta(Map<String, dynamic>? meta) {
    if (meta == null || meta.isEmpty) {
      return const ToolTurnSignals._();
    }

    final finishReason = _firstLowercasedString(meta, const [
      ['finish_reason'],
      ['response', 'finish_reason'],
      ['provider', 'finish_reason'],
      ['choice', 'finish_reason'],
      ['choices', 0, 'finish_reason'],
    ]);
    final stopReason = _firstLowercasedString(meta, const [
      ['stop_reason'],
      ['response', 'stop_reason'],
      ['provider', 'stop_reason'],
      ['choice', 'stop_reason'],
      ['choices', 0, 'stop_reason'],
    ]);

    return ToolTurnSignals._(
      stopReason: stopReason,
      finishReason: finishReason,
      rawMeta: Map<String, dynamic>.from(meta),
    );
  }

  static String? _firstLowercasedString(
    Map<String, dynamic> root,
    List<List<Object>> paths,
  ) {
    for (final path in paths) {
      final value = _readPath(root, path);
      if (value is! String) continue;
      final normalized = value.trim().toLowerCase();
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return null;
  }

  static Object? _readPath(Object? current, List<Object> path) {
    Object? cursor = current;
    for (final segment in path) {
      if (cursor is Map) {
        cursor = cursor[segment];
        continue;
      }
      if (cursor is List && segment is int) {
        if (segment < 0 || segment >= cursor.length) {
          return null;
        }
        cursor = cursor[segment];
        continue;
      }
      return null;
    }
    return cursor;
  }
}

/// Marks a call whose arguments did not parse, so the executor can report
/// that instead of running the tool with nothing.
const String _kMalformedArgumentsKey = '__malformed_arguments__';

class ToolCallHandler {
  ToolCallHandler._internal() {
    registerBuiltinTools(_toolExecutor);
    // Connected MCP servers add their tools to the same executor, and keep
    // adding and removing them as the reader connects and disconnects.
    watchMcpConnections(_toolExecutor);
    unawaited(
      McpService.load().then((_) {
        syncMcpTools(_toolExecutor);
        // Pull connectors synced from other devices. A no-op until the reader
        // is signed in with an encryption key; the chat-sync tick retries.
        return McpSyncService.pullAndReconcile();
      }),
    );
    // The built-in Chukdoo connector works the same way: its tools follow
    // the connector state, and a connector paired on another install of the
    // account is pulled in from the encrypted cloud copy.
    watchChukdooConnector(_toolExecutor);
    syncChukdooTools(_toolExecutor);
    unawaited(ChukdooConnector.instance.pull(force: true));
    unawaited(_toolExecutor.loadPreferences());
    unawaited(platform_tools.initPlatformServices());
    // Fire-and-forget: until it lands only built-ins are in the catalog,
    // which costs a capability, never correctness. Signed-out or key-less
    // starts resolve to an empty list rather than throwing. After the local
    // skills load, reconcile against the remote catalog (adds new skills,
    // silently updates pristine ones, queues suggestions for edited ones).
    unawaited(
      SkillRegistry.refreshUserSkills().then(
        (_) => SkillsCatalogService.reconcile(),
      ),
    );
  }

  static final ToolCallHandler _instance = ToolCallHandler._internal();

  /// Upstream's client-side tool loop below. The first call builds it, which
  /// starts the tool registry, the MCP watchers and the skill catalog.
  ///
  /// A turn does not take its loop from here: it asks [forChat], because in
  /// the Agents build the chat decides which loop runs.
  factory ToolCallHandler() => _instance;

  /// The loop for [chatId]'s turn. An Agents thread
  /// ([ChatOrigin.isAgentsThread]) gets [AgentsToolCallHandler]: the host runs
  /// every tool and the fold only puts the host's run into the reply. Every
  /// other chat gets upstream's loop, a chuk_chat chat in the Agents build
  /// included. Resolve it when the turn starts, not once per screen.
  static ToolCallHandler forChat(String? chatId) =>
      ChatOrigin.isAgentsThread(chatId)
      ? AgentsToolCallHandler.instance
      : _instance;

  /// Builds upstream's loop now instead of at the first send, so the tool
  /// catalog, the MCP connectors and the skills are in place by then.
  /// chuk_chat's chat screen calls this when it mounts; the Agents thread
  /// does not, because the host runs every tool there.
  static void warmUp() => ToolCallHandler();

  final ToolExecutor _toolExecutor = ToolExecutor();
  static const int _maxEmptyFinalRecoveryAttempts = 3;
  static const int _maxMalformedToolProtocolRecoveryAttempts = 2;
  static const int _maxTruncatedCompletionRecoveryAttempts = 2;
  static const int _maxDeferredActionRecoveryAttempts = 2;
  static const int _maxNonFinalTurnRecoveryAttempts = 1;

  /// One-shot self-verification pass before a tool-grounded answer is shown.
  static const int _maxFactCheckRecoveryAttempts = 1;

  /// Tools whose results carry no verifiable real-world facts. When EVERY
  /// tool call in a turn falls in this set, the fact-check pass is skipped —
  /// there is nothing to verify against sources (a coin flip, a generated
  /// image, a UUID). Information-retrieval tools (web_search, web_crawl,
  /// data lookups, …) are intentionally absent so they trigger the pass.
  static const Set<String> _nonFactualToolNames = {
    'find_tools',
    'notes',
    'ask_user',
    // Returns a Connect-button marker, not a real-world fact. Without this a
    // turn whose only tool call was request_mcp_server would fire a spurious
    // [VERIFY] round against nothing.
    'request_mcp_server',
    'flip_coin',
    'roll_dice',
    'random_number',
    'countdown',
    'password_generator',
    'uuid_generator',
    'generate_qr',
    'calculate',
    'generate_image',
    'fetch_image',
    // Hands files over; the result is a delivery receipt, not facts.
    'fetch_files',
    // `skill` returns an acknowledgement, not facts. Without this entry a
    // turn whose only tool call was `skill()` would trigger a full [VERIFY]
    // round-trip that fact-checks an ack against nothing.
    'skill',
    // Artifact hosting returns a published URL, not verifiable facts. Without
    // these entries a turn whose only tool call was create/update_artifact
    // would fire a spurious [VERIFY] fact-check round against nothing.
    'create_artifact',
    'update_artifact',
  };

  static const int _maxDiscoveryContexts = 200;

  /// Ceiling on skills tracked as active in one chat (their `allowed-tools`
  /// stay discovered). A body is sent once, as a `<skill_content>` message,
  /// so this no longer bounds prompt size. Activating a fourth skill evicts
  /// the least-recently activated one.
  static const int _maxActiveSkillsPerChat = 3;
  final Map<String, _DiscoveryContextState> _discoveryContextStates =
      <String, _DiscoveryContextState>{};

  ToolExecutor get toolExecutor => _toolExecutor;

  ToolLoopSession createSession({
    required String initialUserMessage,
    required List<Map<String, dynamic>> history,
    required String accessToken,
    String? discoveryContextKey,
    String? baseSystemPrompt,
    String? modelId,
    bool toolCallingEnabled = true,
    bool discoveryMode = true,
    bool skipIdentity = false,
    bool nativeToolCalling = false,
    String? userSentAt,
  }) {
    // Pin the chat id on the executor for the duration of this send. The
    // `discoveryContextKey` carries the active chat id from the send
    // logic — treat it as authoritative for tool invocations so
    // artifact_manager / typst_compile never race static-state
    // propagation on the first turn of a newly-created chat.
    _toolExecutor.currentChatId = discoveryContextKey;
    final enforcer = ToolEnforcer(maxIterations: kMaxToolRoundsPerTurn)
      ..resetIteration();

    // Tell the enforcer which tools bypass discovery.
    final bypass = <String>{};
    if (WorkspaceStorageService.selectedWorkspaceId != null) {
      bypass.add('update_project');
    }
    if (kFeatureArtifacts) {
      bypass.add('artifact_manager');
    }
    if (bypass.isNotEmpty) {
      enforcer.alwaysAllowedTools = bypass;
    }

    // The chat's frozen prompt inputs travel with the built history
    // (ChatHistoryBuilder attaches them); read them before the clone.
    final historyContext = HistoryPromptContext.of(history);
    final session = ToolLoopSession(
      latestUserMessage: initialUserMessage,
      userSentAt: userSentAt,
      promptSnapshot: historyContext?.snapshot,
      promptEffective: historyContext?.effective,
      toolHistory: historyContext?.toolHistory ?? true,
      history: _cloneHistory(history),
      accessToken: accessToken,
      enforcer: enforcer,
      toolCallingEnabled: toolCallingEnabled,
      discoveryMode: discoveryMode,
      baseSystemPrompt: baseSystemPrompt,
      discoveryContextKey: discoveryContextKey,
      modelId: modelId,
      skipIdentity: skipIdentity,
      nativeToolCalling: nativeToolCalling,
    );

    // Not gated on discoveryMode: skills must survive across user turns even
    // when tool discovery is switched off, and the restore is a no-op when
    // there is nothing stored.
    if (toolCallingEnabled) {
      _restoreDiscoveryContext(session);
    }

    return session;
  }

  /// The system prompt of the turn. Also prepares the turn's user message
  /// ([ToolLoopSession.firstPassMessage]): its `[Sent: …]` line and, when
  /// soul / user info / memory or the MCP servers changed since the chat's
  /// snapshot, a tagged note. Call it before the first pass.
  Future<String> buildInitialSystemPrompt(ToolLoopSession session) async {
    await _prepareTurnContext(session);
    if (!session.toolCallingEnabled) {
      // Even when tools are disabled the per-model prompt should still apply,
      // so route through the merge helper rather than returning the raw base.
      final base = session.baseSystemPrompt?.trim() ?? '';
      final merged = await _applyPerModelPrompt(
        base: base,
        modelId: session.modelId,
      );
      return merged ?? base;
    }

    return _systemPromptFor(session);
  }

  /// The prompt inputs as they are now.
  Future<PromptState> _currentPromptState(ToolLoopSession session) async {
    final identityOn = !session.skipIdentity && await isIdentityEnabled();
    var soul = '';
    var user = '';
    var memory = '';
    if (identityOn) {
      final results = await Future.wait([
        loadSoulText(),
        loadUserInfoText(),
        loadMemoryText(),
      ]);
      soul = results[0].trim();
      user = results[1].trim();
      memory = results[2].trim();
    }
    return PromptState(
      identity: identityOn,
      soul: soul,
      user: user,
      memory: memory,
      mcpConnected: [
        ...McpService.connections.value.map((c) => c.name),
        if (ChukdooConnector.instance.state.value.connected)
          ChukdooConnector.displayName,
      ],
      mcpUnconnected: unconnectedCatalogueEntries().map((e) => e.id).toList(),
      skills: _liveSkillCatalog()
          .map((s) => SkillCatalogEntry(s.name, s.description))
          .toList(),
    );
  }

  /// The skills catalog as it is now: empty when the `skill` tool is not
  /// registered (that build emits no catalog).
  List<Skill> _liveSkillCatalog() =>
      _toolExecutor.allTools.any((t) => t.name == 'skill')
      ? SkillRegistry.all
      : const <Skill>[];

  /// Takes the chat's snapshot (first request) or compares the inputs with
  /// it and writes a tagged note for each change, then renders the turn's
  /// user message. Runs once per session.
  Future<void> _prepareTurnContext(ToolLoopSession session) async {
    if (session._contextPrepared) return;
    session._contextPrepared = true;
    final notes = <String>[];
    // The user text as this turn sends it (with document bodies, before the
    // notes and the `[Sent: …]` line). Stored, so the next turn replays
    // exactly this, not the display text (dropped in storage when equal).
    final sentText = session.latestUserMessage.trim();
    if (sentText.isNotEmpty) session.turnContext.sent = sentText;
    if (session.toolCallingEnabled) {
      final current = await _currentPromptState(session);
      final snapshot = session.promptSnapshot;
      if (snapshot == null) {
        final taken = current.withExtras(toolHistory: session.toolHistory);
        session.promptSnapshot = taken;
        session.turnContext.snapshot = taken;
      } else {
        final before = session.promptEffective ?? snapshot;
        if (!before.sameIdentityAs(current)) {
          notes.add(memoryUpdatedNote(current));
        }
        if (!before.sameMcpAs(current)) {
          notes.add(
            connectorsUpdatedNote(current, native: session.nativeToolCalling),
          );
        }
        if (!_effectiveSkills(before).sameSkillsAs(current)) {
          notes.add(skillsUpdatedNote(current));
        }
        if (notes.isNotEmpty) {
          session.turnContext.notes.addAll(notes);
          // Only what changed against the state the history builder has
          // reached here (`before`): soul, user info and memory are not
          // stored again with every change.
          final diff = current.diffFrom(before);
          if (diff != null) {
            session.turnContext.stateDiff = diff;
          } else {
            session.turnContext.state = current;
          }
        }
      }
    }
    final rendered = renderUserTurnForModel(
      text: session.latestUserMessage,
      sentAt: session.userSentAt,
      notes: notes,
    );
    session.latestUserMessage = rendered;
    session.firstPassMessage = rendered;
    PromptContextLedger.put(session.userSentAt, session.turnContext);
  }

  /// The note that replaces the identity copy of the system prompt.
  @visibleForTesting
  static String memoryUpdatedNote(PromptState state) {
    if (!state.identity) {
      return '[memory updated] Memory is now off for this chat. Do not use '
          'the soul, user info and memory of the system prompt any more.';
    }
    return '[memory updated] The soul, user info and memory below replace '
            'the copies in the system prompt.\n'
            '${ToolPromptBuilder.identityDataSection(state.soul, state.user, state.memory)}'
        .trimRight();
  }

  /// [state] with its skills catalog; an unrecorded one (an older snapshot)
  /// counts as the live catalog, so it gives no note.
  PromptState _effectiveSkills(PromptState state) => state.skills != null
      ? state
      : state.withExtras(
          skills: _liveSkillCatalog()
              .map((s) => SkillCatalogEntry(s.name, s.description))
              .toList(),
        );

  /// The note that replaces the skills list of the system prompt.
  @visibleForTesting
  static String skillsUpdatedNote(PromptState state) {
    final skills = state.skills ?? const <SkillCatalogEntry>[];
    if (skills.isEmpty) {
      return '[skills updated] No skills are available any more. Do not '
          'load the skills listed in the system prompt.';
    }
    return [
      '[skills updated] This list replaces the skills list of the system '
          'prompt. Load a skill with the `skill` tool as described there.',
      for (final skill in skills) '- ${skill.name}: ${skill.description}',
    ].join('\n');
  }

  /// The note that replaces the MCP SERVERS block of the system prompt.
  @visibleForTesting
  static String connectorsUpdatedNote(PromptState state, {bool native = true}) {
    return '[connectors updated] This list replaces the MCP SERVERS block of '
            'the system prompt.\n'
            '${ToolPromptBuilder.mcpServersSection(state.mcpUnconnected, state.mcpConnected, native: native)}'
        .trimRight();
  }

  /// The chat's system prompt, built once per session and then re-sent as
  /// it is, so every pass of the turn starts with the same bytes.
  Future<String> _systemPromptFor(ToolLoopSession session) async {
    final frozen = session.frozenSystemPrompt;
    if (frozen != null) return frozen;
    if (!session._contextPrepared) await _prepareTurnContext(session);
    final prompt = await _buildSystemPrompt(session);
    session.frozenSystemPrompt = prompt;
    return prompt;
  }

  /// The enabled tools as native OpenAI function definitions, for the request's
  /// `tools[]` array. Built-in tools carry synthesized JSON Schema; MCP tools
  /// carry their native `inputSchema`. Sent on every pass of the loop (the
  /// router re-validates the schema each call). Returns empty when tool calling
  /// is off or the session is not in native mode — the prompt-based path then
  /// applies. Mirrors the prompt build: `notes` is withheld when memory is
  /// disabled so it can never be invoked to overwrite/delete memory.
  ///
  /// Once the tools are shut ([ToolLoopSession.toolsShut]) the list stays the
  /// same and [nativeToolChoice] says `none` instead. Dropping `tools[]` for
  /// the forced final pass changed the request prefix, so the provider's
  /// prompt cache missed on the whole history.
  List<Map<String, dynamic>> nativeToolDefinitions(ToolLoopSession session) {
    if (!session.toolCallingEnabled || !session.nativeToolCalling) {
      return const <Map<String, dynamic>>[];
    }
    return _toolExecutor.allTools
        // find_tools is a discovery meta-tool: pointless in native mode, where
        // every tool is already declared in tools[]. notes is withheld when
        // memory is disabled so it can't overwrite/delete memory.
        .where((t) => t.name != 'find_tools')
        .where((t) => !session.skipIdentity || t.name != 'notes')
        .map((t) => t.toOpenAiFunction())
        .toList();
  }

  /// The `tool_choice` for the next request: `none` once the tools are shut in
  /// a native session (the model may only answer), else null (the server's
  /// default, `auto`).
  ///
  /// Static on purpose: `AgentsToolCallHandler` implements this class as an
  /// interface, and a new instance member would break it.
  static String? nativeToolChoice(ToolLoopSession session) {
    if (!session.toolCallingEnabled || !session.nativeToolCalling) return null;
    return session.toolsShut ? 'none' : null;
  }

  /// The forced final pass. Sets [ToolLoopSession.toolsClosed] (the next
  /// request keeps its tool definitions with `tool_choice: none`) and continues with
  /// [kForcedFinalAnswerNote] as the user turn. This round's calls are not
  /// run and, for a native round, not recorded: the history then ends with
  /// the previous round's complete tool results, which keeps every
  /// `tool_call_id` paired. After [_maxForcedFinalPasses] the turn ends with
  /// the text the model wrote (tool-call blocks removed) or, when there is
  /// none, [_toolLimitFallbackMessage].
  Future<ToolLoopResult> _forceFinalAnswer(
    ToolLoopSession session, {
    required String content,
    required String reasoning,
  }) async {
    session.toolsClosed = true;
    if (session.forcedFinalPasses >= _maxForcedFinalPasses) {
      final written = _stripToolCallBlocks(content).trim();
      return ToolLoopResult.finalAnswer(
        content: written.isNotEmpty
            ? written
            : _toolLimitFallbackMessage(session),
        reasoning: reasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }
    session.forcedFinalPasses++;
    session.latestUserMessage = kForcedFinalAnswerNote;
    return ToolLoopResult.continueWith(
      nextStep: ToolLoopStep(
        message: kForcedFinalAnswerNote,
        history: _stepHistory(session),
        turnUserIndex: session.turnUserIndex,
        systemPrompt: await _systemPromptFor(session),
      ),
      interimContent: '',
      toolCalls: _cloneToolCalls(session.toolCalls),
    );
  }

  /// Last resort when even the forced final passes produced no text. If the
  /// turn already produced deliverables (a compiled PDF, an artifact, a
  /// generated image), say the work is done and name what was delivered.
  /// Otherwise point at the collected results and offer the summary. Never
  /// the old "tool-call safety limit, try a simpler prompt" apology. Decides
  /// structurally from completed, non-error tool calls, never from text.
  String _toolLimitFallbackMessage(ToolLoopSession session) {
    bool completed(bool Function(ToolCall) test) => session.toolCalls.any(
      (tc) => tc.status == ToolCallStatus.completed && test(tc),
    );

    // Deduped, order-preserving list of what this turn delivered.
    final delivered = <String>{};
    // A typst_compile is "completed" even when the source failed to compile —
    // its result then carries the compiler error and no "version:", and no
    // artifact card is shown (see message_bubble/tools.dart). Only count it as
    // a delivered PDF when a version was actually persisted, or we would tell
    // the user a PDF is ready when none exists.
    if (completed(
      (tc) =>
          tc.name == 'typst_compile' &&
          tc.result != null &&
          RegExp(r'version:\s*\d+').hasMatch(tc.result!),
    )) {
      delivered.add('the PDF');
    }
    if (completed(
      (tc) =>
          tc.name == 'artifact_manager' &&
          const {
            'create',
            'rewrite',
            'update',
          }.contains((tc.arguments['action'] ?? '').toString()),
    )) {
      delivered.add('the artifact');
    }
    if (completed(
      (tc) => tc.name == 'create_artifact' || tc.name == 'update_artifact',
    )) {
      delivered.add('the artifact');
    }
    if (completed((tc) => tc.name == 'generate_image')) {
      delivered.add('the image');
    }

    if (delivered.isEmpty) {
      return 'I collected the results shown above but could not write the '
          'answer from them. Ask me to sum them up and I will answer without '
          'new searches.';
    }

    final list = delivered.toList();
    final String what;
    if (list.length == 1) {
      what = list.first;
    } else if (list.length == 2) {
      what = '${list[0]} and ${list[1]}';
    } else {
      what =
          '${list.sublist(0, list.length - 1).join(', ')}, '
          'and ${list.last}';
    }
    return 'Your work is ready above — $what is done. I reached the '
        'tool-call limit for this turn while trying to do more, but the '
        'result is already complete.';
  }

  Future<ToolLoopResult> processAssistantResponse({
    required ToolLoopSession session,
    required String content,
    required String reasoning,
    ToolTurnSignals? turnSignals,
    void Function(List<ToolCall>)? onToolCallsUpdated,
    List<NativeToolCall> nativeToolCalls = const <NativeToolCall>[],
  }) async {
    final enforcer = session.enforcer;
    // Some providers (e.g. Fireworks + Kimi) emit the entire assistant
    // response — including <tool_call> blocks — inside `reasoning_content`
    // while leaving the `content` stream empty. Rescue those tool calls by
    // splitting the reasoning text at the first <tool_call> boundary and
    // treating the remainder as real content.
    var effectiveContent = content;
    var effectiveReasoning = reasoning;

    // Some providers (Kimi K2.5 on Fireworks) emit <thinking> blocks in the
    // content channel while the actual tool calls end up in the reasoning
    // channel.  Strip full <thinking>/<think> blocks (tags + inner text) to
    // determine whether the content is *effectively* empty for rescue purposes.
    final contentSansThinking = content
        .replaceAll(
          RegExp(r'<thinking>[\s\S]*?</thinking>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          '',
        )
        .trim();

    if (contentSansThinking.isEmpty && reasoning.contains('<tool_call>')) {
      final idx = reasoning.indexOf('<tool_call>');
      effectiveReasoning = reasoning.substring(0, idx).trim();
      effectiveContent = reasoning.substring(idx);
    } else {
      // Trailing-tool-call rescue: when reasoning ENDS with one or more
      // </tool_call> blocks (the model "intended" to invoke a tool but emitted
      // it into the reasoning channel after a normal answer), lift those
      // trailing blocks into content so the parser can dispatch them.
      // Only fires when the last non-whitespace content of reasoning is a
      // closing tool_call tag — strong signal of "meant to call this".
      final trimmedReasoning = effectiveReasoning.trimRight();
      if (trimmedReasoning.toLowerCase().endsWith('</tool_call>')) {
        final liftStart = _trailingToolCallBlockStart(trimmedReasoning);
        if (liftStart != null) {
          final lifted = trimmedReasoning.substring(liftStart);
          effectiveReasoning = trimmedReasoning.substring(0, liftStart).trim();
          effectiveContent = effectiveContent.isEmpty
              ? lifted
              : '${effectiveContent.trimRight()}\n$lifted';
        }
      }
    }

    final hallucinationCheck = enforcer.checkForHallucination(effectiveContent);
    // Strip literal `<thinking>` / `<think>` wrapper tags — some providers
    // emit them inline in the content stream, which then renders as visible
    // gibberish in the chat UI.
    final cleanedContent = _stripThinkingTags(hallucinationCheck.cleanedContent)
        .trim();

    if (!session.toolCallingEnabled) {
      final displayContent = _stripToolCallBlocks(cleanedContent);
      return ToolLoopResult.finalAnswer(
        content: displayContent.isEmpty ? cleanedContent : displayContent,
        reasoning: effectiveReasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    final roundThinking = _extractRoundThinking(
      content: cleanedContent,
      reasoning: effectiveReasoning,
    );

    // Native tool calling: when the provider streamed structured tool_calls
    // (assembled server-side), use them directly and drive a native
    // assistant(tool_calls) + tool round-trip below. The plain history append
    // is skipped for such a turn — the native round-trip records the assistant
    // message WITH its tool_calls so the upstream sees a valid function-calling
    // history. A turn with no native calls (a final text answer, or a
    // prompt-based model) falls through to the existing text path unchanged.
    //
    // A reply cut off at the token limit (`finish_reason` `length`) may end in
    // the middle of a tool call's arguments. Running such calls would act on
    // half a JSON object, so none of them run: the round is kept as plain
    // text and the "continue" pass below asks the model to finish.
    final bool truncatedNativeRound =
        nativeToolCalls.isNotEmpty &&
        (turnSignals?.indicatesTruncated ?? false) &&
        session.truncatedCompletionRecoveryAttempts <
            _maxTruncatedCompletionRecoveryAttempts;
    final isNativeToolTurn =
        nativeToolCalls.isNotEmpty && !truncatedNativeRound;

    if (isNativeToolTurn) {
      // Record the user turn now — native turns skip the plain history append,
      // and the assistant(tool_calls) + tool results are appended at
      // round-trip time. Doing the user turn here (not in the round-trip) means
      // it survives a turn that ends via an early rejection/return path before
      // the round-trip is reached. On a continuation pass latestUserMessage is
      // empty, so nothing is added twice.
      final priorUser = session.latestUserMessage.trim();
      if (priorUser.isNotEmpty) {
        _noteTurnUserEntry(session, priorUser);
        session.history.add({'role': 'user', 'content': priorUser});
      }
    } else {
      _appendRoundToHistory(
        session,
        assistantContent: cleanedContent,
        assistantReasoning: roundThinking,
      );
    }

    final List<Map<String, dynamic>> parsedCalls;
    if (isNativeToolTurn) {
      parsedCalls = _nativeCallsToParsed(session, nativeToolCalls);
    } else if (truncatedNativeRound) {
      parsedCalls = const <Map<String, dynamic>>[];
    } else {
      parsedCalls = parseToolCalls(cleanedContent);
    }
    if (parsedCalls.isEmpty) {
      final displayContent = _stripToolCallBlocks(cleanedContent);
      final markerInContent = hasToolCallStartMarker(cleanedContent);
      final markerInReasoning = hasToolCallStartMarker(effectiveReasoning);
      final hasToolProtocolMarker = markerInContent || markerInReasoning;
      final signaledToolUse = turnSignals?.indicatesToolUse ?? false;
      final signaledTruncated = turnSignals?.indicatesTruncated ?? false;

      final shouldRetryAfterMalformedToolProtocol =
          !session.toolsShut &&
          (signaledToolUse || hasToolProtocolMarker) &&
          session.malformedToolProtocolRecoveryAttempts <
              _maxMalformedToolProtocolRecoveryAttempts;

      if (shouldRetryAfterMalformedToolProtocol) {
        session.malformedToolProtocolRecoveryAttempts++;

        const retryMessage =
            'Tool Results:\n'
            '[INFO] The previous response indicated tool usage, but no valid '
            'tool call could be parsed.\n\n'
            'If tools are needed, emit a valid <tool_call> now. '
            'Otherwise, provide the final user-facing answer directly now.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _stepHistory(session),
            turnUserIndex: session.turnUserIndex,
            systemPrompt: await _systemPromptFor(session),
          ),
          interimContent: '',
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      final shouldRetryAfterTruncatedCompletion =
          signaledTruncated &&
          session.truncatedCompletionRecoveryAttempts <
              _maxTruncatedCompletionRecoveryAttempts;

      if (shouldRetryAfterTruncatedCompletion) {
        session.truncatedCompletionRecoveryAttempts++;
        final retryMessage = truncatedNativeRound
            ? 'Tool Results:\n'
                  '[INFO] The previous response was cut off by the token '
                  'limit while it was writing tool calls. None of those '
                  'calls were run.\n\n'
                  'If tools are still needed, call them again with complete '
                  'arguments. Otherwise continue and complete the response '
                  'for the user. Do not restart from the beginning.'
            : 'Tool Results:\n'
                  '[INFO] The previous response was cut off by the token '
                  'limit.\n\n'
                  'Continue from where you stopped and complete the response '
                  'for the user. Do not restart from the beginning.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _stepHistory(session),
            turnUserIndex: session.turnUserIndex,
            systemPrompt: await _systemPromptFor(session),
          ),
          interimContent: displayContent,
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      final shouldRetryAfterDeferredAction =
          !session.toolsShut &&
          _looksLikeDeferredActionWithoutToolCall(displayContent) &&
          session.deferredActionRecoveryAttempts <
              _maxDeferredActionRecoveryAttempts;

      if (shouldRetryAfterDeferredAction) {
        session.deferredActionRecoveryAttempts++;
        const retryMessage =
            'Tool Results:\n'
            '[INFO] Your previous response said you would perform an action '
            '(search/check/lookup), but no tool call was emitted.\n\n'
            'If external information is required, call the appropriate '
            'tool(s) now. Otherwise, provide the final answer directly now '
            'without saying you will do it later.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _stepHistory(session),
            turnUserIndex: session.turnUserIndex,
            systemPrompt: await _systemPromptFor(session),
          ),
          // Preserve interim "I'm checking..." text in the UI while the loop
          // continues with the next tool round.
          interimContent: displayContent,
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      // Only treat the turn as "non-final" when the provider actually emitted
      // a stop/finish reason that we recognize as non-final. Absent/unknown
      // signals (Fireworks + Kimi often omit a finish_reason entirely) must
      // NOT trigger a retry — otherwise the model gets asked to "continue"
      // after a complete answer and re-emits the same response, surfacing as
      // a duplicated/reformulated answer below the first one.
      final hasExplicitTurnSignal =
          (turnSignals?.stopReason?.isNotEmpty ?? false) ||
          (turnSignals?.finishReason?.isNotEmpty ?? false);
      final isNonFinalSignaledTurn =
          (turnSignals != null) &&
          hasExplicitTurnSignal &&
          !signaledToolUse &&
          !signaledTruncated &&
          !(turnSignals.indicatesFinalStop);
      final shouldRetryAfterNonFinalTurn =
          !session.toolsShut &&
          session.toolCalls.isNotEmpty &&
          displayContent.trim().isNotEmpty &&
          isNonFinalSignaledTurn &&
          session.nonFinalTurnRecoveryAttempts <
              _maxNonFinalTurnRecoveryAttempts;

      if (shouldRetryAfterNonFinalTurn) {
        session.nonFinalTurnRecoveryAttempts++;
        const retryMessage =
            'Tool Results:\n'
            '[INFO] The previous assistant turn appears non-final while the '
            'tool loop is active.\n\n'
            'Continue this response now. If additional tools are required, '
            'emit valid <tool_call> blocks. If no more tools are needed, '
            'provide the final user-facing answer now.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _stepHistory(session),
            turnUserIndex: session.turnUserIndex,
            systemPrompt: await _systemPromptFor(session),
          ),
          interimContent: displayContent,
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      final shouldRetryAfterEmptyResponse =
          displayContent.trim().isEmpty &&
          session.toolCalls.isNotEmpty &&
          // A pending fact-check candidate is a valid grounded answer — commit
          // it (resolution below) instead of re-prompting for an empty reply.
          session.factCheckCandidate == null &&
          session.emptyFinalRecoveryAttempts < _maxEmptyFinalRecoveryAttempts;

      if (shouldRetryAfterEmptyResponse) {
        session.emptyFinalRecoveryAttempts++;

        const retryMessage =
            'Tool Results:\n'
            '[INFO] The previous assistant response was empty.\n\n'
            'Continue from the latest tool results and provide the final '
            'answer to the user now. Do not repeat tool calls unless they '
            'are absolutely required.';

        session.latestUserMessage = retryMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: retryMessage,
            history: _stepHistory(session),
            turnUserIndex: session.turnUserIndex,
            systemPrompt: await _systemPromptFor(session),
          ),
          interimContent: '',
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      // FACT-CHECK PASS — universal self-verification before a tool-grounded
      // answer is committed. The model produced a candidate answer with no
      // further tool calls. Force ONE verification round: re-check every
      // factual claim against the tool results gathered this turn (entity
      // identity, date/number plausibility, source support, contradictions).
      // The model may correct the answer OR call a tool to resolve a gap —
      // so this re-enters the tool loop rather than only re-prompting text.
      //
      // Gated on a fact-bearing tool having run (web_search, web_crawl, data
      // lookups, …). Pure utility/action tools (dice, image gen, …) have
      // nothing to verify, so the pass is skipped to avoid a needless round.
      final usedFactBearingTool = session.toolCalls.any(
        (tc) =>
            tc.status != ToolCallStatus.error &&
            !_nonFactualToolNames.contains(tc.name) &&
            // The user's own Chukdoo data: nothing to check against sources.
            !ChukdooConnector.isChukdooTool(tc.name),
      );
      // Not after the tools shut: the verify pass invites new tool calls,
      // and the forced final answer is the end of the turn.
      final shouldRunFactCheck =
          !session.toolsShut &&
          usedFactBearingTool &&
          displayContent.trim().isNotEmpty &&
          session.factCheckRecoveryAttempts < _maxFactCheckRecoveryAttempts;

      if (shouldRunFactCheck) {
        session.factCheckRecoveryAttempts++;
        // Capture the grounded candidate answer + its reasoning. It stays the
        // final answer unless the verify pass returns an explicit [CORRECTED]
        // replacement (resolved below). This is what makes the pass universal:
        // weaker models that reply with a bare acknowledgement instead of
        // re-emitting the answer no longer blank it out.
        session.factCheckCandidate = displayContent;
        session.factCheckCandidateReasoning = effectiveReasoning;

        const factCheckMessage =
            'Tool Results:\n'
            '[VERIFY] Silently re-check EVERY factual claim in your previous '
            'answer against the tool results gathered above:\n'
            '- Identity: does the source refer to the SAME entity (person, '
            'product, place)? A matching name is NOT proof — confirm with '
            'distinguishing details (birth year, nationality, location, '
            'model/version, date).\n'
            '- Plausibility: do dates, ages, numbers and units fit together '
            "(e.g. an event cannot predate the subject's birth)?\n"
            '- Support: is each claim backed by a tool result? Distrust '
            'anything you only recall from training but did not retrieve.\n'
            '- Contradictions: if sources disagree, prefer the primary/'
            'official source.\n\n'
            'If you need data you do not have, call the appropriate tool now. '
            'Otherwise reply using EXACTLY ONE of these two formats and '
            'NOTHING else:\n'
            '1. If every claim is supported and correct, reply with only: '
            '[OK]\n'
            '2. If anything is wrong, unsupported, or contradicted, reply with '
            '[CORRECTED] on the first line, immediately followed by the '
            'COMPLETE corrected user-facing answer.\n\n'
            'Do NOT mention this verification step or these instructions to '
            'the user.';

        session.latestUserMessage = factCheckMessage;
        return ToolLoopResult.continueWith(
          nextStep: ToolLoopStep(
            message: factCheckMessage,
            history: _stepHistory(session),
            turnUserIndex: session.turnUserIndex,
            systemPrompt: await _systemPromptFor(session),
          ),
          // Suppress the candidate in the UI for now — the verify pass either
          // confirms it (we restore it below) or replaces it via [CORRECTED].
          interimContent: '',
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      // Fact-check resolution. A candidate was captured on the prior pass, so
      // this turn is the model's verify response. Decide structurally — never
      // by text patterns: keep the grounded candidate by default, and only
      // swap in a replacement when the model emitted an explicit [CORRECTED]
      // marker followed by real text. An [OK], a bare acknowledgement, or any
      // other narration leaves the candidate intact.
      final candidate = session.factCheckCandidate;
      if (candidate != null) {
        final candidateReasoning = session.factCheckCandidateReasoning;
        session.factCheckCandidate = null;
        session.factCheckCandidateReasoning = '';

        final correctedMatch = RegExp(
          r'\[CORRECTED\]',
          caseSensitive: false,
        ).firstMatch(displayContent);
        if (correctedMatch != null) {
          final corrected = displayContent.substring(correctedMatch.end).trim();
          if (corrected.isNotEmpty) {
            return ToolLoopResult.finalAnswer(
              content: corrected,
              reasoning: effectiveReasoning,
              toolCalls: _cloneToolCalls(session.toolCalls),
            );
          }
        }

        return ToolLoopResult.finalAnswer(
          content: candidate,
          reasoning: candidateReasoning,
          toolCalls: _cloneToolCalls(session.toolCalls),
        );
      }

      return ToolLoopResult.finalAnswer(
        content: displayContent,
        reasoning: effectiveReasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    // When memory is disabled (skipIdentity), suppress the notes tool from
    // both the enforcer's declared list and the prompt's tools section so
    // the assistant cannot call it (no overwrite/delete of memory).
    final declaredTools = _toolExecutor.allTools
        .where((t) => !session.skipIdentity || t.name != 'notes')
        .map((t) => t.toJson())
        .toList();
    enforcer.setDeclaredTools(declaredTools);
    enforcer.discoveryMode = session.discoveryMode;
    enforcer.discoveredToolNames = session.discoveredToolNames;

    // Tools are shut (repeated lookups, or the driver's pass budget is nearly
    // spent) and the model asks for more anyway: run nothing, force the
    // answer. Checked before the enforcer so this round is not counted.
    if (session.toolsShut) {
      return _forceFinalAnswer(
        session,
        content: cleanedContent,
        reasoning: effectiveReasoning,
      );
    }

    final enforceResult = enforcer.enforce(parsedCalls);

    // Round limit: the calls of this round are not run. Instead of the old
    // "safety limit" apology, one more pass goes out with no tools, so the
    // user gets an answer from the results already collected.
    if (enforceResult.iterationLimitReached) {
      return _forceFinalAnswer(
        session,
        content: cleanedContent,
        reasoning: effectiveReasoning,
      );
    }

    for (final rejected in enforceResult.rejectedCalls) {
      session.toolCalls.add(
        ToolCall(
          id: rejected.callId,
          name: rejected.name,
          arguments: rejected.arguments,
          result: 'Rejected: ${rejected.reason}',
          status: ToolCallStatus.error,
        ),
      );
    }

    if (enforceResult.rejectedCalls.isNotEmpty) {
      onToolCallsUpdated?.call(_cloneToolCalls(session.toolCalls));
    }

    if (!enforceResult.hasValidCalls) {
      final rejectionLines = enforceResult.rejectedCalls
          .map((r) => '[REJECTED] ${r.name}: ${r.reason}')
          .join('\n');

      final nextMessage =
          'Tool Results:\n'
          '$rejectionLines\n\n'
          'Please use only available tools and try again.';

      session.latestUserMessage = nextMessage;
      return ToolLoopResult.continueWith(
        nextStep: ToolLoopStep(
          message: nextMessage,
          history: _stepHistory(session),
          turnUserIndex: session.turnUserIndex,
          systemPrompt: await _systemPromptFor(session),
        ),
        interimContent: _stripToolCallBlocks(cleanedContent),
        interimBeforeToolCalls: _hasInterimTextBeforeToolCalls(cleanedContent),
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    // Results this turn already holds, keyed by call identity. A read-only
    // lookup repeated with the same arguments is answered from here instead
    // of being run again (see [repeatableLookupToolNames]).
    final priorResults = <String, String>{};
    for (final prior in session.toolCalls) {
      if (prior.status != ToolCallStatus.completed) continue;
      if (!repeatableLookupToolNames.contains(prior.name)) continue;
      final result = prior.result;
      if (result == null) continue;
      // The first real result stands; a repeat answered from here must not
      // replace it with its own "[REPEATED CALL]" copy.
      priorResults.putIfAbsent(
        toolCallIdentityKey(prior.name, prior.arguments),
        () => result,
      );
    }
    bool isRepeat(EnforcedToolCall call) =>
        !call.arguments.containsKey(_kMalformedArgumentsKey) &&
        priorResults.containsKey(
          toolCallIdentityKey(call.name, call.arguments),
        );

    // A fact-check pass that asks only for data the turn already holds has
    // nothing new to check against. Keep the grounded candidate, exactly as
    // an [OK] would. Without this a model can re-run the same lookup until
    // the safety limit: "what is the weather in Kiel" ran `weather` twenty
    // times and ended in the safety-limit apology instead of the answer it
    // had already written.
    final bool onlyRepeats =
        enforceResult.validCalls.isNotEmpty &&
        enforceResult.validCalls.every(isRepeat);
    final bool anyRepeat = enforceResult.validCalls.any(isRepeat);
    final pendingCandidate = session.factCheckCandidate;
    if (pendingCandidate != null && onlyRepeats) {
      final candidateReasoning = session.factCheckCandidateReasoning;
      session.factCheckCandidate = null;
      session.factCheckCandidateReasoning = '';
      return ToolLoopResult.finalAnswer(
        content: pendingCandidate,
        reasoning: candidateReasoning,
        toolCalls: _cloneToolCalls(session.toolCalls),
      );
    }

    // Outside a fact-check the same model can do it before it ever answers:
    // one `weather` call, then the same call again on every pass. The first
    // such round is answered from the held results with a note. If the model
    // asks yet again, the tools close: the results still go back (a native
    // tool call needs its tool message), but the next pass carries no tool
    // definitions, so the model can only answer. Should it still ask after
    // that, the forced final pass runs (see [_forceFinalAnswer]).
    bool closingTools = false;
    if (anyRepeat) {
      session.repeatedLookupRounds++;
      if (session.repeatedLookupRounds >= 2) {
        session.toolsClosed = true;
        closingTools = true;
      }
    }

    final uiCallsById = <String, ToolCall>{};
    for (int i = 0; i < enforceResult.validCalls.length; i++) {
      final call = enforceResult.validCalls[i];
      final uiCall = ToolCall(
        id: call.callId,
        name: call.name,
        arguments: call.arguments,
        status: ToolCallStatus.running,
        roundThinking: i == 0 ? roundThinking : null,
      );
      session.toolCalls.add(uiCall);
      uiCallsById[call.callId] = uiCall;
    }
    onToolCallsUpdated?.call(_cloneToolCalls(session.toolCalls));

    final modelResults = <ToolCallResult>[];
    // Snapshot the session.producedBlocks length BEFORE this round's tool
    // calls so we can slice off only the blocks added in this round and
    // return them via ToolLoopResult.producedBlocks.
    final producedBlocksBefore = session.producedBlocks.length;

    // A round that only looks things up starts all of its calls at once.
    // "When is it open" wants a web search and a places lookup, and running
    // those back to back doubles the wait for nothing. Results are still
    // collected in order below, so the model sees them exactly as before.
    // Anything that writes — notes, artifacts, the device — stays
    // sequential, because with those the order is part of the meaning.
    final inFlight = <String, Future<dynamic>>{};
    final startedThisRound = <String>{};
    if (enforceResult.validCalls.length > 1 &&
        enforceResult.validCalls.every(
          (call) =>
              _readOnlyToolNames.contains(call.name) ||
              ChukdooConnector.instance.isReadOnlyTool(call.name),
        )) {
      for (final call in enforceResult.validCalls) {
        // A call whose arguments did not parse is reported below instead of
        // being run, so starting it here would execute it anyway and leave
        // an unawaited future behind.
        if (call.arguments.containsKey(_kMalformedArgumentsKey)) continue;
        if (isRepeat(call)) continue;
        // The same lookup twice in one round runs once; the second copy is
        // answered from the first result in the loop below.
        if (repeatableLookupToolNames.contains(call.name) &&
            !startedThisRound.add(
              toolCallIdentityKey(call.name, call.arguments),
            )) {
          continue;
        }
        inFlight[call.callId] = _toolExecutor.execute(
          call.name,
          call.arguments,
          accessToken: session.accessToken,
        );
      }
    }

    for (final call in enforceResult.validCalls) {
      final uiCall = uiCallsById[call.callId]!;

      String rawResult;
      bool isError;
      if (call.arguments.containsKey(_kMalformedArgumentsKey)) {
        // The provider's argument stream did not arrive as valid JSON. Saying
        // so beats running the tool with nothing, which answers "No URL
        // provided" and reads to the model like a correct call.
        rawResult =
            'Error: the arguments of this call were not valid JSON, so it '
            'was not run. Send the call again with complete arguments. '
            'Received: ${call.arguments[_kMalformedArgumentsKey]}';
        isError = true;
      } else if (isRepeat(call)) {
        rawResult =
            '$kRepeatedToolCallNote'
            '${closingTools ? ' $kToolsClosedNote' : ''}\n\n'
            '${priorResults[toolCallIdentityKey(call.name, call.arguments)]}';
        isError = false;
      } else {
        try {
          final executionResult =
              await (inFlight[call.callId] ??
                  _toolExecutor.execute(
                    call.name,
                    call.arguments,
                    accessToken: session.accessToken,
                  ));
          rawResult = executionResult.output;
          isError = executionResult.isError;
          if (executionResult.producedBlocks.isNotEmpty) {
            session.producedBlocks.addAll(executionResult.producedBlocks);
          }
          // Later copies of this lookup in the same round reuse the result.
          if (!isError && repeatableLookupToolNames.contains(call.name)) {
            priorResults.putIfAbsent(
              toolCallIdentityKey(call.name, call.arguments),
              () => rawResult,
            );
          }
        } catch (error) {
          rawResult = 'Error executing ${call.name}: $error';
          isError = true;
        }
      }

      if (call.name == 'find_tools' && !isError) {
        _updateDiscoveredTools(session, rawResult);
      }
      if (call.name == 'skill' && !isError) {
        _updateActiveSkills(session, rawResult);
      }

      uiCall.result = rawResult;
      uiCall.completedAt = DateTime.now();
      uiCall.status = isError ? ToolCallStatus.error : ToolCallStatus.completed;
      onToolCallsUpdated?.call(_cloneToolCalls(session.toolCalls));

      modelResults.add(
        ToolCallResult(
          callId: call.callId,
          name: call.name,
          // Capped once, here: this text is what the history keeps and
          // every later pass re-sends.
          result: capToolResultForModel(sanitizeResultForModel(rawResult)),
          isError: isError,
        ),
      );
    }

    final String nextMessage;
    if (isNativeToolTurn) {
      // Native round-trip. The user turn was already recorded at the top of
      // this method. Record the assistant turn WITH its tool_calls and one tool
      // message per result, then continue with an empty user message — the tool
      // results ARE the model's next input, not a synthetic user turn.
      // tool_call_id matches the assistant tool_calls id (the enforcer keeps
      // the provider's native id), which is what the stateless upstream needs.
      //
      // Calls the enforcer rejected (unknown tool, bad find_tools query) are
      // part of the round too, each with a `Rejected: <reason>` result.
      // Leaving them out meant the model never heard that they failed and
      // waited for, or repeated, a call that would never run. All calls keep
      // the order the model wrote them in.
      final validById = <String, EnforcedToolCall>{
        for (final call in enforceResult.validCalls) call.callId: call,
      };
      final rejectedById = <String, RejectedToolCall>{
        for (final rejected in enforceResult.rejectedCalls)
          if (rejected.callId != null) rejected.callId!: rejected,
      };
      final resultById = <String, String>{
        for (final result in modelResults) result.callId: result.result,
        for (final rejected in rejectedById.values)
          rejected.callId!: 'Rejected: ${rejected.reason}',
      };
      final orderedIds = <String>[
        for (final parsed in parsedCalls)
          if (validById.containsKey(parsed['id']) ||
              rejectedById.containsKey(parsed['id']))
            parsed['id'] as String,
      ];
      final assistantToolCalls = <Map<String, dynamic>>[
        for (final id in orderedIds)
          {
            'id': id,
            'type': 'function',
            'function': {
              'name': validById[id]?.name ?? rejectedById[id]!.name,
              'arguments': jsonEncode(
                validById[id]?.arguments ?? rejectedById[id]!.arguments,
              ),
            },
          },
      ];
      final interim = _stripToolCallBlocks(cleanedContent).trim();
      session.history.add({
        'role': 'assistant',
        'content': interim.isEmpty ? null : interim,
        'tool_calls': assistantToolCalls,
      });
      for (final id in orderedIds) {
        session.history.add({
          'role': 'tool',
          'tool_call_id': id,
          'content': resultById[id] ?? kUnansweredToolCallResult,
        });
      }
      // A skill loaded in this round: its body follows the tool results as
      // a user message, appended (never put into the system prompt).
      for (final skill in _takePendingSkillContents(session)) {
        session.history.add({
          'role': 'user',
          'content': skillContentMessage(skill.name, skill.body),
        });
      }
      nextMessage = '';
      session.latestUserMessage = '';
    } else {
      final skillMessages = [
        for (final skill in _takePendingSkillContents(session))
          skillContentMessage(skill.name, skill.body),
      ];
      nextMessage = [
        enforcer.buildResultMessage(modelResults),
        ...skillMessages,
      ].join('\n\n');
      session.latestUserMessage = nextMessage;
    }

    final orderedUiCalls = enforceResult.validCalls
        .map((c) => uiCallsById[c.callId])
        .whereType<ToolCall>()
        .toList();
    final interleaved = _splitInterleavedSegments(
      cleanedContent,
      orderedUiCalls,
    );

    return ToolLoopResult.continueWith(
      nextStep: ToolLoopStep(
        message: nextMessage,
        history: _stepHistory(session),
        turnUserIndex: session.turnUserIndex,
        systemPrompt: await _systemPromptFor(session),
      ),
      // Preserve all non-tool text from this pass (before/after tool blocks)
      // so assistant text is never lost across multi-pass tool loops.
      interimContent: _stripToolCallBlocks(cleanedContent),
      interimBeforeToolCalls: _hasInterimTextBeforeToolCalls(cleanedContent),
      toolCalls: _cloneToolCalls(session.toolCalls),
      interleavedSegments: interleaved,
      // Forward any side-effect blocks emitted by tools this round
      // (e.g. a places lookup -> `<map>` block).
      producedBlocks: session.producedBlocks.length > producedBlocksBefore
          ? List<ContentBlock>.unmodifiable(
              session.producedBlocks.sublist(producedBlocksBefore),
            )
          : const <ContentBlock>[],
    );
  }

  /// Walks [content] in source order and splits it into text chunks /
  /// individual tool calls based on the positions of `<tool_call>` blocks.
  ///
  /// Returns an empty list when interleaving cannot be reliably reconstructed
  /// (mismatched span/tool count, or a single span with no surrounding text)
  /// — callers fall back to the legacy bundled rendering in that case.
  List<RoundSegment> _splitInterleavedSegments(
    String content,
    List<ToolCall> uiCalls,
  ) {
    if (uiCalls.isEmpty) return const [];

    final spans = RegExp(
      r'<tool_call>[\s\S]*?</tool_call>',
      caseSensitive: false,
    ).allMatches(content).toList();

    // Mismatch (e.g. some tool calls were rejected, or the markdown form
    // was used) → fall back to legacy rendering.
    if (spans.length != uiCalls.length) return const [];

    final segments = <RoundSegment>[];
    var cursor = 0;
    for (var i = 0; i < spans.length; i++) {
      final span = spans[i];
      final between = content.substring(cursor, span.start).trim();
      if (between.isNotEmpty) {
        segments.add(RoundSegment.text(between));
      }
      segments.add(RoundSegment.toolCall(uiCalls[i]));
      cursor = span.end;
    }
    final tail = content.substring(cursor).trim();
    if (tail.isNotEmpty) {
      segments.add(RoundSegment.text(tail));
    }

    // Don't bother reporting an interleaved view when there was no genuine
    // interleaving — legacy rendering handles "all tools, then optional
    // tail text" cleanly.
    final hasInterleavedText = segments.any(
      (s) => s.isText && segments.indexOf(s) < segments.length - 1,
    );
    final hasMultipleToolGroups = _countToolGroups(segments) > 1;
    if (!hasInterleavedText && !hasMultipleToolGroups) return const [];

    return segments;
  }

  static int _countToolGroups(List<RoundSegment> segments) {
    var groups = 0;
    var inGroup = false;
    for (final s in segments) {
      if (s.isToolCall) {
        if (!inGroup) {
          groups += 1;
          inGroup = true;
        }
      } else {
        inGroup = false;
      }
    }
    return groups;
  }

  /// Convert native (structured) tool calls into the parsed-call shape the
  /// enforcer and executor consume. `arguments` arrives as a JSON string;
  /// parse it defensively — providers occasionally emit malformed or truncated
  /// JSON, in which case the call runs with empty args rather than crashing the
  /// whole turn.
  ///
  /// Every call gets an id that is unique in this conversation: a missing id
  /// gets one, and an id already used (twice in this round, or the server's
  /// fallback `call_<n>` repeating every round) gets a `_2`, `_3`, ... suffix.
  /// Two calls with one id overwrote each other in the running and result
  /// maps. The new id is used for the assistant `tool_calls` and the tool
  /// result alike, so the model sees a matching pair.
  List<Map<String, dynamic>> _nativeCallsToParsed(
    ToolLoopSession session,
    List<NativeToolCall> calls,
  ) {
    final usedIds = _usedToolCallIds(session);
    return calls.map((call) {
      final id = uniqueToolCallId(
        call.id.trim().isNotEmpty ? call.id.trim() : 'call_${usedIds.length}',
        usedIds,
      );
      Map<String, dynamic> args = <String, dynamic>{};
      final raw = call.arguments.trim();
      if (raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            args = decoded;
          } else if (decoded is Map) {
            args = decoded.map((k, v) => MapEntry(k.toString(), v));
          } else {
            // Valid JSON, wrong shape: a list, a bare string, null. The tool
            // would run with nothing, exactly as with unparseable input.
            args = <String, dynamic>{
              _kMalformedArgumentsKey: raw.length > 200
                  ? '${raw.substring(0, 200)}…'
                  : raw,
            };
          }
        } on FormatException {
          // Malformed argument JSON. Running with empty args makes the tool
          // answer "No URL provided", which reads to the model as if it had
          // called correctly, so it repeats the same call. Say what went
          // wrong instead; the retry then carries real arguments.
          args = <String, dynamic>{
            _kMalformedArgumentsKey: raw.length > 200
                ? '${raw.substring(0, 200)}…'
                : raw,
          };
        }
      }
      return <String, dynamic>{
        'name': call.name,
        'arguments': args,
        // Carry the provider's native tool-call id (made unique above) so the
        // enforcer uses it as the callId — the assistant.tool_calls[].id and
        // role:"tool" tool_call_id then match.
        'id': id,
      };
    }).toList();
  }

  /// Tool-call ids already used in [session]: in its history and its calls.
  Set<String> _usedToolCallIds(ToolLoopSession session) {
    final used = <String>{};
    for (final message in session.history) {
      final calls = message['tool_calls'];
      if (calls is List) {
        for (final call in calls) {
          if (call is Map && call['id'] != null) {
            used.add(call['id'].toString());
          }
        }
      }
    }
    for (final call in session.toolCalls) {
      used.add(call.id);
    }
    return used;
  }

  void _appendRoundToHistory(
    ToolLoopSession session, {
    required String assistantContent,
    String? assistantReasoning,
  }) {
    final userText = session.latestUserMessage.trim();
    if (userText.isNotEmpty) {
      _noteTurnUserEntry(session, userText);
      session.history.add({'role': 'user', 'content': userText});
    }

    final reasoningText = assistantReasoning?.trim() ?? '';
    var assistantText = assistantContent.trim();
    if (reasoningText.isNotEmpty && assistantText.startsWith(reasoningText)) {
      assistantText = assistantText.substring(reasoningText.length).trim();
    }

    if (reasoningText.isEmpty && assistantText.isNotEmpty) {
      session.history.add({'role': 'assistant', 'content': assistantText});
      return;
    }

    if (reasoningText.isNotEmpty) {
      final withThinking = assistantText.isEmpty
          ? '<thinking>\n$reasoningText\n</thinking>'
          : '<thinking>\n$reasoningText\n</thinking>\n\n$assistantText';
      session.history.add({'role': 'assistant', 'content': withThinking});
    }
  }

  void _updateDiscoveredTools(ToolLoopSession session, String findToolsResult) {
    final matches = RegExp(
      r'^TOOL:\s*(\S+)',
      multiLine: true,
    ).allMatches(findToolsResult);
    final discoveredNames = matches
        .map((match) => match.group(1))
        .whereType<String>()
        .toSet();

    if (discoveredNames.isEmpty) return;

    var hasNewTool = false;
    for (final tool in _toolExecutor.allTools) {
      if (tool.name == 'find_tools') continue;
      if (!discoveredNames.contains(tool.name)) continue;
      if (session.discoveredToolNames.contains(tool.name)) continue;

      session.discoveredToolNames.add(tool.name);
      hasNewTool = true;
    }

    if (!hasNewTool) {
      return;
    }

    _refreshDiscoveredToolDefinitions(session);
    _storeDiscoveryContext(session);

    if (kDebugMode) {
      debugPrint(
        '[ToolDiscovery] Discovered: '
        '${session.discoveredToolNames.join(', ')}',
      );
    }
  }

  /// Records a skill activation from the `skill` tool's acknowledgement.
  ///
  /// Scrapes the `SKILL: <name>` first line, mirroring how
  /// [_updateDiscoveredTools] scrapes `TOOL: <name>` out of find_tools. The
  /// marker only appears on success, so an error acknowledgement is ignored
  /// without needing the executor to flag it.
  void _updateActiveSkills(ToolLoopSession session, String skillResult) {
    final match = RegExp(
      r'^SKILL:\s*(\S+)',
      multiLine: true,
    ).firstMatch(skillResult);
    final name = match?.group(1);
    if (name == null) return;

    final skill = SkillRegistry.byName(name);
    if (skill == null) return;

    // The body goes to the model once per chat, as a `<skill_content>` user
    // message after this round's tool results (see processAssistantResponse).
    // A skill the history already carries is not sent again.
    if (!historyHasSkillContent(session.history, skill.name) &&
        !session.pendingSkillContents.any((s) => s.name == skill.name)) {
      session.pendingSkillContents.add(SkillContent(skill.name, skill.body));
    }

    // Re-activating an already-active skill moves it to most-recent rather
    // than duplicating it.
    session.activeSkillNames
      ..remove(skill.name)
      ..add(skill.name);
    while (session.activeSkillNames.length > _maxActiveSkillsPerChat) {
      session.activeSkillNames.removeAt(0);
    }

    // `allowed-tools` pre-approves tools: mark them discovered so their full
    // definitions land in the same prompt rebuild that carries the body.
    // Filtered against the enabled set — a skill must never resurrect a tool
    // the user switched off.
    final enabledToolNames = _toolExecutor.allTools
        .map((tool) => tool.name)
        .toSet();
    var hasNewTool = false;
    for (final toolName in skill.allowedTools) {
      if (toolName == 'find_tools') continue;
      if (!enabledToolNames.contains(toolName)) continue;
      if (session.discoveredToolNames.add(toolName)) {
        hasNewTool = true;
      }
    }
    if (hasNewTool) {
      _refreshDiscoveredToolDefinitions(session);
    }

    _storeDiscoveryContext(session);

    if (kDebugMode) {
      debugPrint('[Skills] Active: ${session.activeSkillNames.join(', ')}');
    }
  }

  /// Builds the system prompt from the chat's snapshot
  /// ([ToolLoopSession.promptSnapshot]), not from the live soul / memory /
  /// MCP state: those change during a chat, and a changed system prompt
  /// misses the prompt cache on the whole history. Use [_systemPromptFor].
  Future<String> _buildSystemPrompt(ToolLoopSession session) async {
    final baseSystemPrompt = session.baseSystemPrompt;
    final discoveryMode = session.discoveryMode;
    final skipIdentity = session.skipIdentity;
    final nativeToolCalling = session.nativeToolCalling;
    final modelId = session.modelId;
    final snapshot = session.promptSnapshot ?? const PromptState();
    final identityOn = snapshot.identity;

    String? soulText;
    String? userInfoText;
    String? memoryText;
    Map<String, dynamic>? notesToolDef;

    if (identityOn) {
      soulText = snapshot.soul;
      userInfoText = snapshot.user;
      memoryText = snapshot.memory;

      // Get the notes tool definition so it's always available.
      notesToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'notes')
          .map((t) => t.toJson())
          .firstOrNull;
    }

    // ask_user is always available regardless of identity toggle.
    final askUserToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'ask_user')
        .map((t) => t.toJson())
        .firstOrNull;

    // request_mcp_server is always available: the model must be able to offer
    // a Connect button for a server the request needs. The server lists come
    // from the chat's snapshot; a later connect or disconnect reaches the
    // model as a `[connectors updated]` note on the next user message.
    final requestMcpServerToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'request_mcp_server')
        .map((t) => t.toJson())
        .firstOrNull;
    final unconnectedMcpServers = snapshot.mcpUnconnected
        .map(catalogueEntryById)
        .whereType<McpCatalogueEntry>()
        .toList();
    final connectedMcpServerNames = snapshot.mcpConnected;

    // web_search and web_crawl are always available in discovery mode.
    // web_search handles image search too (type="images") so the AI can
    // reach for real photos without another tool registration.
    final webSearchToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'web_search')
        .map((t) => t.toJson())
        .firstOrNull;
    final webCrawlToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'web_crawl')
        .map((t) => t.toJson())
        .firstOrNull;
    // Places sits next to web search rather than behind discovery: a
    // question about a shop's hours wants both in the first response, and
    // a tool the model must discover first cannot be part of that.
    final searchPlacesToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'search_places')
        .map((t) => t.toJson())
        .firstOrNull;

    // search_chats is always available: the AI must be able to recover the
    // subject of a prior-conversation reference without a discovery round-trip.
    final searchChatsToolDef = _toolExecutor.allTools
        .where((t) => t.name == 'search_chats')
        .map((t) => t.toJson())
        .firstOrNull;

    // update_project is always available when a workspace is active.
    Map<String, dynamic>? projectToolDef;
    if (WorkspaceStorageService.selectedWorkspaceId != null) {
      projectToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'update_project')
          .map((t) => t.toJson())
          .firstOrNull;
    }

    // artifact_manager is always available when the feature is enabled —
    // treat it like chart/map/email output, no discovery needed.
    // Chat scoping happens at execute time (tool_executor.dart).
    Map<String, dynamic>? artifactToolDef;
    Map<String, dynamic>? artifactSchemaToolDef;
    if (kFeatureArtifacts) {
      artifactToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'artifact_manager')
          .map((t) => t.toJson())
          .firstOrNull;
      artifactSchemaToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'artifact_schema')
          .map((t) => t.toJson())
          .firstOrNull;
    }

    // Skills. The `skill` tool's presence in the executor is the single
    // source of truth for the catalog: a build that removed it (or a platform
    // that never registered it) emits no tool, no catalog and no gating.
    final skillsEnabled = _toolExecutor.allTools.any((t) => t.name == 'skill');
    Map<String, dynamic>? skillToolDef;
    List<Skill> skillCatalog = const [];
    if (skillsEnabled) {
      skillToolDef = _toolExecutor.allTools
          .where((t) => t.name == 'skill')
          .map((t) => t.toJson())
          .firstOrNull;
      // From the chat's snapshot: a catalog change reaches the model as a
      // `[skills updated]` note on the next user message.
      final frozen = snapshot.skills;
      skillCatalog = frozen == null
          ? SkillRegistry.all
          : [
              for (final entry in frozen)
                Skill(
                  name: entry.name,
                  description: entry.description,
                  body: '',
                ),
            ];
    }

    // When memory is disabled (skipIdentity), exclude the `notes` tool from
    // the prompt's tool list so the assistant can't invoke it to
    // overwrite/delete memory. Identity text injection is already gated above.
    final tools = _toolExecutor.allTools
        .where((t) => !skipIdentity || t.name != 'notes')
        .map((t) => t.toJson())
        .toList();
    final promptBuilder = ToolPromptBuilder(discoveryMode: discoveryMode);
    final toolProtocol = promptBuilder
        .buildToolProtocolSection(
          tools: tools,
          nativeToolCalling: nativeToolCalling,
          soulText: soulText,
          userInfoText: userInfoText,
          memoryText: memoryText,
          notesToolDef: notesToolDef,
          askUserToolDef: askUserToolDef,
          requestMcpServerToolDef: requestMcpServerToolDef,
          unconnectedMcpServers: unconnectedMcpServers,
          connectedMcpServerNames: connectedMcpServerNames,
          webSearchToolDef: webSearchToolDef,
          searchPlacesToolDef: searchPlacesToolDef,
          webCrawlToolDef: webCrawlToolDef,
          searchChatsToolDef: searchChatsToolDef,
          projectToolDef: projectToolDef,
          artifactToolDef: artifactToolDef,
          artifactSchemaToolDef: artifactSchemaToolDef,
          skillToolDef: skillToolDef,
          skillCatalog: skillCatalog,
        )
        .trim();

    final mergedBase = await _applyPerModelPrompt(
      base: baseSystemPrompt,
      modelId: modelId,
    );
    final base = mergedBase?.trim();
    if (base == null || base.isEmpty) return toolProtocol;

    return '$base\n\n$toolProtocol';
  }

  /// Merge the per-model prompt for [modelId] into [base] using the saved
  /// [ModelPromptMode]. Returns [base] unchanged when no per-model config
  /// exists or the model id is empty.
  Future<String?> _applyPerModelPrompt({
    required String? base,
    required String? modelId,
  }) async {
    final id = modelId?.trim();
    if (id == null || id.isEmpty) return base;
    try {
      final cfg = await PerModelSystemPromptService.get(id);
      if (cfg == null || !cfg.isActive) return base;
      final merged = mergeModelPrompt(
        base: base,
        modelPrompt: cfg.prompt,
        mode: cfg.mode,
      );
      if (kDebugMode) {
        debugPrint(
          '[PerModelPrompt] applied modelId=$id mode=${cfg.mode.name} '
          'baseLen=${base?.length ?? 0} mergedLen=${merged?.length ?? 0}',
        );
      }
      return merged;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] apply failed for $id: $error');
      }
      return base;
    }
  }

  String _stripToolCallBlocks(String content) {
    return stripToolCallBlocksForDisplay(content);
  }

  String _extractPreToolText(String content) {
    final toolStart = _indexOfFirstToolCallBlock(content);
    if (toolStart == -1) {
      return _stripToolCallBlocks(content);
    }

    final preText = content.substring(0, toolStart).trim();
    return preText;
  }

  String? _extractRoundThinking({
    required String content,
    required String reasoning,
  }) {
    final providerReasoning = _stripThinkingTags(reasoning).trim();
    if (providerReasoning.isNotEmpty) {
      return providerReasoning;
    }

    final preToolText = _stripThinkingTags(_extractPreToolText(content)).trim();
    if (preToolText.isEmpty) {
      return null;
    }

    return preToolText;
  }

  /// Some providers (Kimi on Fireworks, DeepSeek) wrap reasoning in
  /// `<thinking>…</thinking>` tags and stream it either inside
  /// `reasoning_content` or inline before the tool calls. Rendering
  /// those tags as literal text looks broken, so strip them.
  static String _stripThinkingTags(String text) {
    var out = text.replaceAll(
      RegExp(r'</?thinking>', caseSensitive: false),
      '',
    );
    out = out.replaceAll(RegExp(r'</?think>', caseSensitive: false), '');
    return out;
  }

  /// Returns the start index of the contiguous run of tool-call blocks
  /// (`<tool_call>…</tool_call>`) that terminate `text` (separated only by
  /// whitespace), or null if `text` does not end in a tool-call block.
  /// Used to lift accidental tool calls out of the reasoning channel.
  @visibleForTesting
  static int? trailingToolCallBlockStart(String text) =>
      _trailingToolCallBlockStartImpl(text);

  int? _trailingToolCallBlockStart(String text) =>
      _trailingToolCallBlockStartImpl(text);

  static int? _trailingToolCallBlockStartImpl(String text) {
    final matches = RegExp(
      r'<tool_call>[\s\S]*?</tool_call>',
      caseSensitive: false,
    ).allMatches(text).toList();
    if (matches.isEmpty) return null;
    if (text.substring(matches.last.end).trim().isNotEmpty) return null;
    var start = matches.last.start;
    var prevStart = matches.last.start;
    for (var i = matches.length - 2; i >= 0; i--) {
      final m = matches[i];
      if (text.substring(m.end, prevStart).trim().isNotEmpty) break;
      start = m.start;
      prevStart = m.start;
    }
    return start;
  }

  int _indexOfFirstToolCallBlock(String content) {
    final xmlIndex = content.indexOf('<tool_call>');
    final markdownMatch = RegExp(
      r'```(?:tool_call|toolcall|tool-call)\s*[\s\S]*?```',
      caseSensitive: false,
    ).firstMatch(content);
    final markdownIndex = markdownMatch?.start ?? -1;

    if (xmlIndex == -1) return markdownIndex;
    if (markdownIndex == -1) return xmlIndex;
    return xmlIndex < markdownIndex ? xmlIndex : markdownIndex;
  }

  bool _hasInterimTextBeforeToolCalls(String content) {
    final firstToolCallIndex = _indexOfFirstToolCallBlock(content);
    if (firstToolCallIndex == -1) {
      return false;
    }

    final preToolText = content.substring(0, firstToolCallIndex).trim();
    if (preToolText.isEmpty) {
      return false;
    }

    final withoutThinkingBlocks = preToolText
        .replaceAll(
          RegExp(r'<thinking>[\s\S]*?</thinking>', caseSensitive: false),
          '',
        )
        .trim();

    return withoutThinkingBlocks.isNotEmpty;
  }

  /// Detects "I'll search/check/lookup..." style deferred-action text that
  /// often appears when a model intends to call tools but emits no call.
  @visibleForTesting
  static bool looksLikeDeferredActionWithoutToolCall(String content) =>
      _looksLikeDeferredActionWithoutToolCall(content);

  static bool _looksLikeDeferredActionWithoutToolCall(String content) {
    final text = content.trim();
    if (text.isEmpty || text.length > 280) {
      return false;
    }

    final normalized = text.toLowerCase();

    // Multi-line / fenced output is a real answer, not a promise of one.
    if (normalized.contains('\n') || normalized.contains('```')) {
      return false;
    }

    // "Let me summarize: Magellan left in 1519." — the answer is delivered in
    // the same breath as the announcement, so this is not a deferred action.
    // A bare trailing colon ("Let me search for X:") still counts as deferred.
    final colonIndex = normalized.indexOf(':');
    if (colonIndex >= 0 &&
        normalized.substring(colonIndex + 1).trim().isNotEmpty) {
      return false;
    }

    // The promise is often preceded by a filler sentence ("I have enough
    // information now. Let me write the summary."), so the last sentence is
    // checked as well as the whole text.
    return _isDeferredIntentSentence(normalized) ||
        _isDeferredIntentSentence(_lastSentence(normalized));
  }

  /// Last sentence of [normalized], or the whole string when it has only one.
  static String _lastSentence(String normalized) {
    final parts = normalized
        .split(RegExp(r'(?<=[.!?:])\s+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.isEmpty ? normalized : parts.last;
  }

  static bool _isDeferredIntentSentence(String sentence) {
    final startsWithIntent = RegExp(
      r"^(ok[,\s]+|sure[,\s]+|alright[,\s]+|now[,\s]+)?"
      r"(first[,\s]+)?"
      r"(i\s*(?:will|'ll)|let me|i(?:’|')m going to|i need to|i should)\b",
    ).hasMatch(sentence);
    final startsWithIntentIntl = RegExp(
      r'^(jetzt\s+)?'
      r"(ich\s+(?:suche|werde|erstelle|schreibe|fasse|recherchiere)|"
      r'lass(?:en\s+sie)?\s+mich|'
      r'je\s+vais|'
      r'voy\s+a|'
      r'vado\s+a|'
      r'eu\s+vou|'
      r'wij\s+gaan|'
      r'we\s+will)\b',
    ).hasMatch(sentence);
    if (!startsWithIntent && !startsWithIntentIntl) {
      return false;
    }

    // Verbs that name work the model still owes the user — either a tool call
    // (search/check) or the answer itself (write/summarize).
    return RegExp(
      r'\b(search|check|look up|lookup|verify|find|fetch|browse|compare|research|pull|'
      r'write|create|draft|compile|prepare|put together|summari[sz]e|summary|'
      // de
      r'suche|recherchiere|erstelle[nr]?|schreibe[nr]?|verfasse[nr]?|'
      r'zusammenfass\w*|pr(?:ü|ue)fe[nr]?|nachschauen|nachsehen|'
      // fr
      r'chercher|rechercher|v(?:é|e)rifier|consulter|r(?:é|e)diger|r(?:é|e)sumer|'
      // es
      r'buscar|investigar|revisar|verificar|escribir|resumir|'
      // pt
      r'procurar|pesquisar|escrever|resumir|'
      // it
      r'cercare|verificare|controllare|scrivere|riassumere|'
      // nl
      r'onderzoek|zoeken|opzoeken|nakijken|schrijven|samenvatten)\b',
    ).hasMatch(sentence);
  }

  /// The history for the next pass: the session history as it is (nothing
  /// that was sent before is rewritten), cloned and pairing-checked.
  List<Map<String, dynamic>> _stepHistory(ToolLoopSession session) {
    // Repair the tool pairing before every request: one orphan or unanswered
    // tool call and the upstream answers 400 for the whole turn.
    final step = validateToolPairing(_cloneHistory(session.history));
    _recordTranscript(session, step);
    return step;
  }

  /// Marks the entry about to be appended at the end of the history as the
  /// turn's own user message, when it is the first pass's message.
  void _noteTurnUserEntry(ToolLoopSession session, String content) {
    if (session.turnUserIndex != null) return;
    if (content != session.firstPassMessage.trim()) return;
    session.turnUserIndex = session.history.length;
  }

  /// Stores, with the turn's user message, what the next pass sends after
  /// that message: the [step] history from the turn's user entry on, then
  /// the pass's own user message ([ToolLoopSession.latestUserMessage],
  /// which the server appends). The last one recorded is the turn's last
  /// request, so the next turn's history replays it byte for byte
  /// (`TurnPromptContext.transcript`).
  void _recordTranscript(
    ToolLoopSession session,
    List<Map<String, dynamic>> step,
  ) {
    final userIndex = session.turnUserIndex;
    if (userIndex == null || userIndex >= step.length) return;
    final transcript = <Map<String, dynamic>>[
      for (final entry in step.sublist(userIndex + 1))
        Map<String, dynamic>.from(entry),
    ];
    final message = session.latestUserMessage.trim();
    if (message.isNotEmpty) {
      transcript.add({'role': 'user', 'content': message});
    }
    session.turnContext.transcript = transcript;
    PromptContextLedger.put(session.userSentAt, session.turnContext);
  }

  /// The skill bodies queued in this round, in load order, and clears them.
  /// Records each in the turn's stored context, so the history of every
  /// later turn sends the same message at the same place.
  List<SkillContent> _takePendingSkillContents(ToolLoopSession session) {
    if (session.pendingSkillContents.isEmpty) return const <SkillContent>[];
    final taken = List<SkillContent>.of(session.pendingSkillContents);
    session.pendingSkillContents.clear();
    session.turnContext.skills.addAll(taken);
    PromptContextLedger.put(session.userSentAt, session.turnContext);
    return taken;
  }

  List<Map<String, dynamic>> _cloneHistory(List<Map<String, dynamic>> history) {
    return history.map((m) => Map<String, dynamic>.from(m)).toList();
  }

  List<ToolCall> _cloneToolCalls(List<ToolCall> calls) {
    return calls.map((c) => ToolCall.fromJson(c.toJson())).toList();
  }

  void _restoreDiscoveryContext(ToolLoopSession session) {
    final contextKey = session.discoveryContextKey?.trim();
    if (contextKey == null || contextKey.isEmpty) {
      return;
    }

    final stored = _discoveryContextStates[contextKey];
    // Check both collections: a skill with no `allowed-tools` — the common
    // case — leaves discoveredToolNames empty, and an early return on that
    // alone would silently drop the activation.
    if (stored == null ||
        (stored.discoveredToolNames.isEmpty &&
            stored.activeSkillNames.isEmpty)) {
      return;
    }

    stored.lastUsedAt = DateTime.now();
    session.discoveredToolNames.addAll(stored.discoveredToolNames);
    session.activeSkillNames
      ..clear()
      ..addAll(stored.activeSkillNames);
    _refreshDiscoveredToolDefinitions(session);
  }

  void _storeDiscoveryContext(ToolLoopSession session) {
    final contextKey = session.discoveryContextKey?.trim();
    if (contextKey == null || contextKey.isEmpty) {
      return;
    }
    if (session.discoveredToolNames.isEmpty &&
        session.activeSkillNames.isEmpty) {
      return;
    }

    final state = _discoveryContextStates.putIfAbsent(
      contextKey,
      _DiscoveryContextState.new,
    );
    state.lastUsedAt = DateTime.now();
    state.discoveredToolNames
      ..clear()
      ..addAll(session.discoveredToolNames);
    state.activeSkillNames
      ..clear()
      ..addAll(session.activeSkillNames);

    _pruneDiscoveryContextsIfNeeded();
  }

  void _refreshDiscoveredToolDefinitions(ToolLoopSession session) {
    final discoveredDefs = _toolExecutor.allTools
        .where(
          (tool) =>
              tool.name != 'find_tools' &&
              session.discoveredToolNames.contains(tool.name),
        )
        .map((tool) => tool.toJson())
        .toList();

    session.discoveredTools
      ..clear()
      ..addAll(discoveredDefs);
  }

  void _pruneDiscoveryContextsIfNeeded() {
    if (_discoveryContextStates.length <= _maxDiscoveryContexts) {
      return;
    }

    final ordered = _discoveryContextStates.entries.toList()
      ..sort((a, b) => a.value.lastUsedAt.compareTo(b.value.lastUsedAt));

    final removeCount = _discoveryContextStates.length - _maxDiscoveryContexts;
    for (int i = 0; i < removeCount; i++) {
      _discoveryContextStates.remove(ordered[i].key);
    }
  }
}

/// Per-chat context that survives across user turns (in memory only — it does
/// not survive an app restart, and neither does tool discovery).
///
/// Skills live here rather than in a parallel map on purpose: a skill's
/// `allowed-tools` marks tools as discovered, so the two are coupled. Two LRU
/// maps would evict independently and leave a skill active whose tools had
/// been forgotten.
class _DiscoveryContextState {
  _DiscoveryContextState();

  DateTime lastUsedAt = DateTime.now();
  final Set<String> discoveredToolNames = <String>{};
  final List<String> activeSkillNames = <String>[];
}
