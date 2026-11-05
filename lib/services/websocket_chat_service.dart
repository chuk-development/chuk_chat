import 'dart:async';


import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/agents/agents_chat_transport.dart';
import 'package:chuk_chat/services/chat_history_builder.dart';
import 'package:chuk_chat/services/client_request_ids.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/prompt_cache/image_budget.dart';
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/services/provider_resolution_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/tool_result_cache_registry.dart';
import 'package:chuk_chat/utils/stream_error_notice.dart';

/// Service for handling streaming chat responses.
///
/// Every chat send — main responses, tool-loop passes, and title
/// generation alike — is routed over the **single** multiplexed `/v2/ws`
/// connection owned by [MultiplexSession]. There is no per-request socket
/// and no legacy `/v1/ai/chat/ws` fallback in this client: one socket per
/// session carries everything, multiplexed by `req_id`. (The backend keeps
/// `/v1/ai/chat/ws` only so older app builds still work.)
///
/// The Agents build (`FEATURE_AGENTS`) carries both kinds of chat, and the
/// chat id picks the path ([usesAgentsTransport]): an Agents thread goes to
/// [AgentsChatTransport], which relays it to the paired host; a chuk_chat chat
/// goes to the hosted API exactly as in a chuk_chat build. A send with no chat
/// id (title generation, the offline executor, the assistant overlay) is not
/// an Agents thread either, so it is hosted too. The stop-intent calls exist
/// only for the Agents transport and do nothing for a chuk_chat chat.
class WebSocketChatService {
  /// Whether a send for [chatId] goes to the paired host. True only for an
  /// Agents thread ([ChatOrigin.isAgentsThread]), which is never true outside
  /// the Agents build.
  static bool usesAgentsTransport(String? chatId) =>
      ChatOrigin.isAgentsThread(chatId);

  /// Declares that the user asked to stop [sessionKey]'s run. Agents threads
  /// only; see [AgentsChatTransport.declareStopIntent].
  ///
  /// For a chuk_chat chat it sends `cancel` with the `client_request_id` of
  /// the chat's running pass ([cancelHostedRequest]): the server stops that
  /// request on any socket, also one it detached after a reconnect, so it
  /// does not run on (and bill) after the user stopped it.
  static void declareStopIntent(String sessionKey) {
    if (usesAgentsTransport(sessionKey)) {
      AgentsChatTransport.declareStopIntent(sessionKey);
    } else {
      cancelHostedRequest(sessionKey);
    }
  }

  /// The `client_request_id` of each chat's latest hosted pass. Kept until
  /// the next pass of the chat replaces it; a cancel of a finished request
  /// does nothing on the server.
  static final Map<String, String> _activeRequestIds = <String, String>{};

  /// The id of [chatId]'s latest hosted pass, or null.
  @visibleForTesting
  static String? activeRequestIdFor(String chatId) => _activeRequestIds[chatId];

  /// Test seam: records [id] as [chatId]'s running pass.
  @visibleForTesting
  static void debugTrackRequest(String chatId, String id) =>
      _activeRequestIds[chatId] = id;

  /// Test seam: where [cancelHostedRequest] sends. Null sends on the open
  /// multiplex connection.
  @visibleForTesting
  static void Function(String clientRequestId)? debugCancelSink;

  /// Sends `cancel` with the `client_request_id` of [chatId]'s latest pass.
  /// The user stopped the reply; see [declareStopIntent].
  static void cancelHostedRequest(String chatId) {
    final id = _activeRequestIds.remove(chatId);
    if (id == null) return;
    final sink = debugCancelSink;
    if (sink != null) {
      sink(id);
      return;
    }
    unawaited(() async {
      try {
        final connection =
            MultiplexSession.current ?? await MultiplexSession.ensureCurrent();
        connection?.cancelClientRequest(id);
      } catch (_) {
        // Best effort: with no socket the server cannot be told now.
      }
    }());
  }

  /// Takes back a declared stop. Agents threads only; see
  /// [AgentsChatTransport.withdrawStopIntent]. With no key it takes back
  /// every declared stop, as before, but only in the Agents build.
  static void withdrawStopIntent([String? sessionKey]) {
    if (!ChatOrigin.agentsEnabled) return;
    if (sessionKey != null && !usesAgentsTransport(sessionKey)) return;
    AgentsChatTransport.withdrawStopIntent(sessionKey);
  }

  /// Test seam: stands in for the hosted send, so a test can see which path a
  /// chat takes without a network. Null (the default) sends for real.
  @visibleForTesting
  static Stream<ChatStreamEvent> Function(String? chatId)? debugHostedSend;

  /// Sends a streaming chat request and yields chunks as they arrive.
  ///
  /// Ensures the shared multiplex connection is open (establishing it on
  /// demand if a send beats [MultiplexSession.openForChat]), then routes
  /// the request through it. When the socket genuinely can't be
  /// established the stream yields an error + done rather than opening a
  /// throwaway connection.
  ///
  /// [accessToken] is accepted for API stability; authentication now flows
  /// through the multiplex handshake (which fetches the token itself), so
  /// it is not used to build the request payload.
  ///
  /// [regenerate] and [modelSelectionCaptured] are Agents-only send flags and
  /// are ignored on the hosted path.
  ///
  /// [turnHistoryIndex]: on a tool-loop pass, the index in [history] of the
  /// turn's own user message (`ToolLoopStep.turnUserIndex`). The server puts
  /// the turn's re-sent images back on that entry (`turn_history_index`).
  ///
  /// [clientRequestId]: the pass's `client_request_id`
  /// ([ClientRequestIds.forPass]). Give the same id on every re-send of the
  /// same pass (reconnect, cache-miss retry, outbox re-send) and a new one
  /// for each new pass; the server then runs and bills each pass once. Null
  /// (title, assistant, compaction) makes one id for this call.
  static Stream<ChatStreamEvent> sendStreamingChat({
    required String accessToken,
    required String message,
    required String modelId,
    required String providerSlug,
    List<Map<String, dynamic>>? history,
    String? systemPrompt,
    int maxTokens = 512,
    double temperature = 0.7,
    List<String>? images,
    String? reasoningEffort,
    String? chatId,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    bool regenerate = false,
    bool modelSelectionCaptured = false,
    String? requestPurpose,
    int? requestPass,
    int? turnHistoryIndex,
    String? clientRequestId,
  }) {
    if (usesAgentsTransport(chatId)) {
      return AgentsChatTransport.sendStreamingChat(
        accessToken: accessToken,
        message: message,
        modelId: modelId,
        providerSlug: providerSlug,
        history: history,
        systemPrompt: systemPrompt,
        maxTokens: maxTokens,
        temperature: temperature,
        images: images,
        reasoningEffort: reasoningEffort,
        chatId: chatId,
        tools: tools,
        regenerate: regenerate,
        modelSelectionCaptured: modelSelectionCaptured,
      );
    }
    final hostedSeam = debugHostedSend;
    if (hostedSeam != null) return hostedSeam(chatId);
    return _sendHosted(
      message: message,
      modelId: modelId,
      providerSlug: providerSlug,
      history: history,
      systemPrompt: systemPrompt,
      maxTokens: maxTokens,
      temperature: temperature,
      images: images,
      reasoningEffort: reasoningEffort,
      chatId: chatId,
      tools: tools,
      toolChoice: toolChoice,
      requestPurpose: requestPurpose,
      requestPass: requestPass,
      turnHistoryIndex: turnHistoryIndex,
      clientRequestId: clientRequestId,
    );
  }

  /// Upstream chuk_chat's send: the shared multiplex connection.
  static Stream<ChatStreamEvent> _sendHosted({
    required String message,
    required String modelId,
    required String providerSlug,
    List<Map<String, dynamic>>? history,
    String? systemPrompt,
    int maxTokens = 512,
    double temperature = 0.7,
    List<String>? images,
    String? reasoningEffort,
    String? chatId,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    String? requestPurpose,
    int? requestPass,
    int? turnHistoryIndex,
    String? clientRequestId,
  }) async* {
    // One connection carries everything. When [chatId] is supplied the
    // multiplex routes through [MultiplexSession.chatForChat] (single
    // in-flight stream per chat id); callers without a chat id (title
    // generation, offline executor) get the un-tracked
    // [MultiplexConnection.chat] over the same socket.
    final connection = await MultiplexSession.ensureCurrent();
    if (connection == null) {
      if (kDebugMode) {
        debugPrint(
          '❌ [WebSocketChatService] multiplex connection unavailable',
        );
      }
      yield const ChatStreamEvent.error(kConnectionErrorNotice);
      yield const ChatStreamEvent.done();
      return;
    }

    yield* _sendViaMultiplex(
      connection: connection,
      message: message,
      modelId: modelId,
      providerSlug: providerSlug,
      history: history,
      systemPrompt: systemPrompt,
      maxTokens: maxTokens,
      temperature: temperature,
      images: images,
      reasoningEffort: reasoningEffort,
      chatId: chatId,
      tools: tools,
      toolChoice: toolChoice,
      requestPurpose: requestPurpose,
      requestPass: requestPass,
      turnHistoryIndex: turnHistoryIndex,
      clientRequestId: clientRequestId,
    );
  }

  /// Send a chat through the multiplexed `/v2/ws` connection. Yields the
  /// [ChatStreamEvent] flow and lets the caller's drain loop handle
  /// book-keeping.
  static Stream<ChatStreamEvent> _sendViaMultiplex({
    required MultiplexConnection connection,
    required String message,
    required String modelId,
    required String providerSlug,
    List<Map<String, dynamic>>? history,
    String? systemPrompt,
    int maxTokens = 512,
    double temperature = 0.7,
    List<String>? images,
    String? reasoningEffort,
    String? chatId,
    List<Map<String, dynamic>>? tools,
    String? toolChoice,
    String? requestPurpose,
    int? requestPass,
    int? turnHistoryIndex,
    String? clientRequestId,
  }) async* {
    // Last guard: the Auto marker is the reader's choice, not a provider the
    // server knows. Every send path resolves it earlier; one that forgot
    // must still not ship it.
    if (ProviderResolutionService.isAuto(providerSlug)) {
      providerSlug =
          await ProviderResolutionService.resolveForSend(modelId, providerSlug) ??
          '';
    }
    if (kDebugMode) {
      debugPrint('📤 [Multiplex] chat -> $modelId via $providerSlug');
    }

    final registry = ToolResultCacheRegistry.instance;

    final payload = <String, dynamic>{
      'message': message,
      'model_id': modelId,
      'provider_slug': providerSlug,
      'max_tokens': maxTokens,
      'temperature': temperature,
      // Request metadata for the server (cache affinity, logs). The server
      // strips it before the upstream call. A hash of the chat id only,
      // nothing about the user.
      'x_chuk': xChukMetadata(
        purpose:
            requestPurpose ??
            (toolChoice == 'none' ? 'final' : 'chat'),
        chatId: chatId,
        pass: requestPass,
      ),
    };

    // Native tool calling: OpenAI-format function defs the model may call this
    // turn. The backend forwards them upstream and streams back tool_calls.
    if (tools != null && tools.isNotEmpty) {
      payload['tools'] = tools;
      // `none` on the forced final pass: the same tools[] (so the prompt
      // cache still hits) but the model may only answer.
      if (toolChoice != null) payload['tool_choice'] = toolChoice;
    }

    // Cache a large message server-side under a client-issued id so later
    // passes of this turn can reference it instead of re-uploading the text.
    // The message still goes up in full this once (the server needs it now).
    if (registry.shouldCache(message)) {
      payload['message_cache_id'] = registry.register(message);
    }

    // The turn's own images, loaded the same way as history images (same
    // bytes, same type label), so the next turn's history repeats them.
    final base64Images = images == null || images.isEmpty
        ? const <String>[]
        : await _convertImagesToBase64(images);

    if (history != null && history.isNotEmpty) {
      // History images: provider limits, oldest cut first in large steps,
      // then loaded (ImageBudget keeps the history byte-stable).
      final budgeted = await ImageBudget.apply(
        history,
        limits: ImageBudget.limitsFor(modelId),
        textOnly:
            ModelCapabilitiesService.supportsImageInputKnownSync(modelId) ==
            false,
        pendingCount: base64Images.length,
        pendingChars: base64Images.fold<int>(0, (sum, i) => sum + i.length),
        resolve: ChatHistoryBuilder.resolveImageDataUrl,
      );
      // On a native tool pass the turn's images sit on its own history
      // entry (cache-stable placement), resolved to full data URLs. When
      // the server still holds every one of them, send them as refs: the
      // server puts them back on that same entry, after its text, so the
      // provider gets the same bytes and only our upload shrinks.
      //
      // The entry is the one the tool loop named ([turnHistoryIndex]), sent
      // as `turn_history_index` so the server picks the same one. Without
      // a name both sides use the same rule ([toolLoopTurnIndex]).
      final turnIndex = message.trim().isEmpty
          ? turnAnchor(budgeted, turnHistoryIndex)
          : null;
      if (turnIndex != null) payload['turn_history_index'] = turnIndex;
      final turnRefs = base64Images.isEmpty
          ? foldTurnImageRefs(budgeted, message, registry, turnIndex: turnIndex)
          : null;
      if (turnRefs != null) {
        payload['image_cache_refs'] = turnRefs.refs;
        if (kDebugMode) {
          debugPrint(
            '🖼️ [Multiplex] turn images: ${turnRefs.refs.length} cached refs',
          );
        }
      }
      // Earlier turns' images go up once: a full block is tagged with a
      // `cache_id` (the server stores it), a block the server holds goes as
      // `image_ref` (the server puts the same block back).
      payload['history'] = foldHistoryImageRefs(
        _foldHistoryRefs(turnRefs?.history ?? budgeted, registry),
        registry,
      );
    }
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      payload['system_prompt'] = systemPrompt;
    }
    if (reasoningEffort != null) {
      payload['reasoning_effort'] = reasoningEffort;
    }
    if (base64Images.isNotEmpty) {
      // Images are the heaviest payload and, because history is text-only,
      // get re-sent on every tool pass. Send each in full ONCE (tagged with a
      // parallel cache id so the server stores it), then reference it by id on
      // later passes — turning megabytes of repeated base64 into a short ref.
      //
      // All by reference or all in full, never mixed: the server puts the
      // referenced images before the full ones, so a mixed request would
      // change their order against the turn's history entry.
      final fullImages = <String>[];
      final fullImageIds = <String>[];
      final imageRefs = <String>[];
      final refs = [for (final img in base64Images) registry.imageRefFor(img)];
      if (refs.every((ref) => ref != null)) {
        imageRefs.addAll(refs.whereType<String>());
      } else {
        for (final img in base64Images) {
          fullImages.add(img);
          fullImageIds.add(registry.registerImage(img));
        }
      }
      if (fullImages.isNotEmpty) {
        payload['images'] = fullImages;
        payload['image_cache_ids'] = fullImageIds;
      }
      if (imageRefs.isNotEmpty) {
        payload['image_cache_refs'] = imageRefs;
      }
      if (kDebugMode) {
        debugPrint(
          '🖼️ [Multiplex] images: ${fullImages.length} full + '
          '${imageRefs.length} cached refs',
        );
      }
    }

    // Request idempotency: one `client_request_id` per pass, the same on
    // every re-send of it (ClientRequestIds). The server runs it once.
    final given = clientRequestId;
    final requestId = given != null && ClientRequestIds.isValid(given)
        ? given
        : ClientRequestIds.fresh();
    payload['client_request_id'] = requestId;
    // The chat's own passes only: a title request of the same chat must not
    // become the target of the user's Stop.
    final bool trackForStop =
        chatId != null && chatId.isNotEmpty && requestPurpose != 'title';
    if (trackForStop) _activeRequestIds[chatId] = requestId;

    // Route through the per-chatId tracker so two concurrent chat
    // streams for the same chat (e.g. title generation racing the
    // main response) can never interleave into the same UI buffer.
    yield* runIdempotent(
      payload: payload,
      send: (p) => MultiplexSession.chatForChat(chatId: chatId, payload: p),
      onRequestId: (id) {
        if (trackForStop) _activeRequestIds[chatId] = id;
      },
    );
  }

  /// Most polls of a request the server still runs (`duplicate_in_flight`)
  /// before the send gives up with [StreamErrorCodes.requestPending].
  static const int maxInFlightPolls = 6;

  /// Test seam: the wait between two polls.
  @visibleForTesting
  static Future<void> Function(Duration) pollDelay = Future<void>.delayed;

  /// Sends [payload] (it holds `client_request_id`) through [send] and
  /// answers the idempotency frames, so callers see a normal answer:
  ///
  /// * `duplicate`: the stored answer, already turned into events by
  ///   [MultiplexConnection.duplicateEvents].
  /// * `duplicate_in_flight`: wait the hint (1 to 5 s) and send the same
  ///   frame again, at most [maxInFlightPolls] times; then an error with
  ///   [StreamErrorCodes.requestPending] (the same id gets the answer later).
  /// * `client_request_id_conflict` / `invalid_client_request_id`: send
  ///   again once with a fresh id ([onRequestId] learns it).
  /// * A transient routing error before any content (`is not available
  ///   on`, `No provider`): send again once. Carried over from the removed
  ///   legacy path. The error released the id, so it is reused.
  @visibleForTesting
  static Stream<ChatStreamEvent> runIdempotent({
    required Map<String, dynamic> payload,
    required Stream<ChatStreamEvent> Function(Map<String, dynamic> payload)
    send,
    void Function(String id)? onRequestId,
  }) async* {
    var retriedTransient = false;
    var renewedId = false;
    var polls = 0;
    var yieldedContent = false;
    while (true) {
      var shouldRetry = false;
      Duration? wait;
      await for (final event in send(payload)) {
        if (shouldRetry) {
          // Drain the rest of the answered attempt (its `done`) unseen.
          continue;
        }
        if (event is ContentEvent ||
            event is ReasoningEvent ||
            event is ToolCallsEvent) {
          yieldedContent = true;
          yield event;
        } else if (event is ErrorEvent) {
          final code = event.code;
          if (code == StreamErrorCodes.duplicateInFlight) {
            if (polls < maxInFlightPolls) {
              polls++;
              shouldRetry = true;
              final hint = event.retryAfterSeconds ?? 2;
              final seconds = hint.clamp(1, 5).toDouble();
              wait = Duration(milliseconds: (seconds * 1000).round());
              if (kDebugMode) {
                debugPrint(
                  '⏳ [Multiplex] request still running, poll $polls '
                  'in ${seconds}s',
                );
              }
              continue;
            }
            yield const ChatStreamEvent.error(
              kAnswerPendingNotice,
              code: StreamErrorCodes.requestPending,
            );
            continue;
          }
          if (!yieldedContent &&
              !renewedId &&
              (code == StreamErrorCodes.clientRequestIdConflict ||
                  code == StreamErrorCodes.invalidClientRequestId)) {
            renewedId = true;
            shouldRetry = true;
            final fresh = ClientRequestIds.fresh();
            payload['client_request_id'] = fresh;
            onRequestId?.call(fresh);
            if (kDebugMode) {
              debugPrint('↻ [Multiplex] request id refused ($code), new id');
            }
            continue;
          }
          final msg = event.message;
          final transient =
              !yieldedContent &&
              !retriedTransient &&
              (msg.contains('is not available on') ||
                  msg.contains('No provider') ||
                  msg.contains('no provider'));
          if (transient) {
            retriedTransient = true;
            shouldRetry = true;
            if (kDebugMode) {
              debugPrint(
                '↻ [Multiplex] transient backend error, retrying once',
              );
            }
            // Abandon this attempt's stream (cancels it server-side) and
            // re-issue below. Do NOT forward the error or the done that
            // chatForChat would append.
            break;
          }
          yield event;
        } else {
          // usage / meta / tps / done — forward unchanged.
          yield event;
        }
      }
      if (!shouldRetry) break;
      if (wait != null) await pollDelay(wait);
    }
  }

  /// Starts of the user messages the tool loop adds itself: a skill body
  /// after a round's results ([skillContentMessage]), the row left for a
  /// dropped one ([skillDroppedMarker]), a text-protocol result or recovery
  /// note (`Tool Results:`), the forced-final note
  /// (`kForcedFinalAnswerNote`). Never the turn's own message. A
  /// `[memory updated]` / `[connectors updated]` / `[skills updated]` note
  /// is not one of them: it heads the turn's own user message
  /// ([renderUserTurnForModel]). Same list as the server's
  /// `SYNTHETIC_USER_PREFIXES` (`chat/history_repair.py`).
  static const List<String> syntheticUserPrefixes = <String>[
    '<skill_content',
    '[skill ',
    'Tool Results:',
    'The tool limit for this turn is reached.',
  ];

  /// True for a user message the tool loop added, not the user's turn.
  @visibleForTesting
  static bool isSyntheticUserMessage(Map<String, dynamic> message) {
    if (message['role'] != 'user') return false;
    final content = message['content'];
    var text = '';
    if (content is String) {
      text = content;
    } else if (content is List) {
      for (final part in content) {
        if (part is Map && part['type'] == 'text') {
          final t = part['text'];
          if (t is String && t.trim().isNotEmpty) {
            text = t;
            break;
          }
        }
      }
    }
    final head = text.trimLeft();
    return syntheticUserPrefixes.any(head.startsWith);
  }

  /// Index of the user message that opened the native tool loop at the end
  /// of [history], or null. The same rule as the server's
  /// `tool_loop_turn_index` (`chat/history_repair.py`) without a named
  /// turn: the loop is the trailing run of assistant `tool_calls` turns,
  /// `tool` results and synthetic user messages ([isSyntheticUserMessage]);
  /// the turn is the nearest user message before its first `tool_calls`
  /// turn that is not synthetic.
  @visibleForTesting
  static int? toolLoopTurnIndex(List<Map<String, dynamic>> history) {
    bool isCallTurn(Map<String, dynamic> m) {
      final calls = m['tool_calls'];
      return m['role'] == 'assistant' && calls is List && calls.isNotEmpty;
    }

    var i = history.length;
    int? firstCall;
    while (i > 0) {
      final msg = history[i - 1];
      if (msg['role'] == 'tool' || isSyntheticUserMessage(msg)) {
        i -= 1;
      } else if (isCallTurn(msg)) {
        firstCall = i - 1;
        i -= 1;
      } else {
        break;
      }
    }
    if (firstCall == null) return null;
    var anchor = firstCall - 1;
    while (anchor >= 0 && isSyntheticUserMessage(history[anchor])) {
      anchor -= 1;
    }
    if (anchor < 0 || history[anchor]['role'] != 'user') return null;
    return anchor;
  }

  /// The turn's own entry in [history] on a native tool pass: [named] (the
  /// tool loop's `turnUserIndex`) when it points at a user message, else
  /// null; without a name, [toolLoopTurnIndex]. A wrong name is never
  /// replaced by a guess, the same as on the server.
  @visibleForTesting
  static int? turnAnchor(List<Map<String, dynamic>> history, int? named) {
    if (named == null) return toolLoopTurnIndex(history);
    if (named < 0 || named >= history.length) return null;
    return history[named]['role'] == 'user' ? named : null;
  }

  /// On a native tool pass (empty [message]), move the turn's images out of
  /// its history entry into `image_cache_refs` when the server still holds
  /// all of them (they went up in full, with cache ids, on pass 1). Returns
  /// null when that is not safe; the history then goes up as it is.
  ///
  /// [turnIndex] is the turn's entry ([turnAnchor], sent as
  /// `turn_history_index`); without it [toolLoopTurnIndex] picks it. The
  /// server's `attach_turn_images` puts ref images back on that same entry,
  /// after its text, so the provider request is byte-identical. That holds
  /// only when:
  /// - the message is empty (else the server puts them on a new user turn,
  ///   so prompt-based passes keep the full images);
  /// - the images are a trailing run after the text, as
  ///   `userContentWithImages` builds them;
  /// - text remains (an image-only entry would be dropped by the server);
  /// - every image is an inline data URL with a fresh registry ref.
  ///
  /// An older turn's images stay in place in its own entry and go as
  /// per-image `image_ref` blocks ([foldHistoryImageRefs]); so does this
  /// turn's entry when this fold is not safe.
  @visibleForTesting
  static ({List<Map<String, dynamic>> history, List<String> refs})?
  foldTurnImageRefs(
    List<Map<String, dynamic>> history,
    String message,
    ToolResultCacheRegistry registry, {
    int? turnIndex,
  }) {
    if (message.trim().isNotEmpty) return null;
    final anchor = turnIndex ?? toolLoopTurnIndex(history);
    if (anchor == null || anchor < 0 || anchor >= history.length) return null;
    if (history[anchor]['role'] != 'user') return null;
    final entry = history[anchor];
    final content = entry['content'];
    if (content is! List) return null;

    final kept = <Map<String, dynamic>>[];
    final refs = <String>[];
    var hasText = false;
    for (final part in content) {
      if (part is! Map) return null;
      if (part['type'] == 'image_url') {
        final image = part['image_url'];
        final url = image is Map ? image['url'] : image;
        if (url is! String || !url.startsWith('data:image/')) return null;
        final ref = registry.imageRefFor(url);
        if (ref == null) return null;
        refs.add(ref);
      } else {
        // Text after an image: the server would put the images after it.
        if (refs.isNotEmpty) return null;
        final text = part['text'];
        if (part['type'] == 'text' && text is String && text.trim().isNotEmpty) {
          hasText = true;
        }
        kept.add(Map<String, dynamic>.from(part));
      }
    }
    if (refs.isEmpty || !hasText) return null;

    // One text part goes as a plain string: the server makes the same text
    // block of it, and a large one can then fold into a `cache_ref` too.
    final Object newContent = kept.length == 1 && kept.single['type'] == 'text'
        ? kept.single['text'] as String
        : kept;
    final out = List<Map<String, dynamic>>.of(history);
    out[anchor] = <String, dynamic>{...entry, 'content': newContent};
    return (history: out, refs: refs);
  }

  /// Replace large `history` entries whose content was already uploaded (and
  /// cached server-side) with a tiny `{role, cache_ref}` marker, so the bytes
  /// travel up the wire only once per turn. Entries that aren't cached (too
  /// small, expired, or never registered) are passed through unchanged and
  /// upload in full. A server `cache_miss` clears the registry and the turn
  /// re-sends everything in full — refs are never a silent data loss.
  static List<Map<String, dynamic>> _foldHistoryRefs(
    List<Map<String, dynamic>> history,
    ToolResultCacheRegistry registry,
  ) {
    return history.map((entry) {
      final content = entry['content'];
      final role = entry['role'];
      if (content is String && role != null && registry.shouldCache(content)) {
        final ref = registry.refFor(content);
        if (ref != null) {
          final folded = <String, dynamic>{'role': role, 'cache_ref': ref};
          // Preserve the native tool-calling fields when folding a large body
          // into a cache ref — dropping tool_call_id (on a role:"tool" message)
          // or tool_calls (on an assistant turn) would leave a tool call
          // unanswered and 400 the upstream request.
          final toolCallId = entry['tool_call_id'];
          if (toolCallId != null) folded['tool_call_id'] = toolCallId;
          final toolCalls = entry['tool_calls'];
          if (toolCalls != null) folded['tool_calls'] = toolCalls;
          return folded;
        }
      }
      return entry;
    }).toList();
  }

  /// Per-image refs in the history's user turns (api_server CLAUDE.md,
  /// "Image refs in history"). Each image block `{type: image_url,
  /// image_url: {url: data:image/...}}`:
  ///
  /// * the server holds it ([ToolResultCacheRegistry.imageRefFor]): sent as
  ///   `{type: image_ref, ref: <id>}`; the server puts back exactly the
  ///   block the full image gives, so the provider bytes do not change;
  /// * else sent in full with a `cache_id` ([registerImage]); the server
  ///   stores it under that id and never sends `cache_id` upstream.
  ///
  /// A block of any other form is left as it is. A server `cache_miss`
  /// clears the registry (and pauses refs), so the retry sends every image
  /// in full, tagged again. Only user turns: the server resolves refs there.
  @visibleForTesting
  static List<Map<String, dynamic>> foldHistoryImageRefs(
    List<Map<String, dynamic>> history,
    ToolResultCacheRegistry registry,
  ) {
    List<Map<String, dynamic>>? out;
    for (var i = 0; i < history.length; i++) {
      final entry = history[i];
      if (entry['role'] != 'user') continue;
      final content = entry['content'];
      if (content is! List) continue;
      List<dynamic>? parts;
      for (var j = 0; j < content.length; j++) {
        final url = _plainImageBlockUrl(content[j]);
        if (url == null) continue;
        final ref = registry.imageRefFor(url);
        parts ??= List<dynamic>.of(content);
        parts[j] = ref != null
            ? <String, dynamic>{'type': 'image_ref', 'ref': ref}
            : <String, dynamic>{
                'type': 'image_url',
                'image_url': <String, dynamic>{'url': url},
                'cache_id': registry.registerImage(url),
              };
      }
      if (parts == null) continue;
      out ??= List<Map<String, dynamic>>.of(history);
      out[i] = <String, dynamic>{...entry, 'content': parts};
    }
    return out ?? history;
  }

  /// The data URL of [part] when it is exactly `{type: image_url,
  /// image_url: {url: data:image/...}}` (what [userContentWithImages]
  /// builds), else null. Any other key would not survive a ref.
  static String? _plainImageBlockUrl(Object? part) {
    if (part is! Map || part['type'] != 'image_url' || part.length != 2) {
      return null;
    }
    final image = part['image_url'];
    if (image is! Map || image.length != 1) return null;
    final url = image['url'];
    if (url is! String || !url.startsWith('data:image/')) return null;
    return url;
  }

  /// Convert image storage paths or existing Base64 URLs to Base64 data URLs.
  /// This is called on-the-fly when sending to AI - images are NOT stored as Base64.
  static Future<List<String>> _convertImagesToBase64(
    List<String> imagePaths,
  ) async {
    final base64Images = <String>[];

    for (final path in imagePaths) {
      // A data URL as it is; a storage path downloaded, decrypted and
      // labelled with its real type. Labelling every image image/jpeg made
      // the turn's bytes differ from the same image in the next history.
      final dataUrl = await ChatHistoryBuilder.resolveImageDataUrl(path);
      if (dataUrl != null) {
        base64Images.add(dataUrl);
      } else if (kDebugMode) {
        debugPrint('⚠️ Failed to convert an image to Base64');
      }
    }

    return base64Images;
  }
}
