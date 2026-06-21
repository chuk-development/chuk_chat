import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/multiplex_connection.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/tool_result_cache_registry.dart';

/// Service for handling streaming chat responses.
///
/// Every chat send — main responses, tool-loop passes, and title
/// generation alike — is routed over the **single** multiplexed `/v2/ws`
/// connection owned by [MultiplexSession]. There is no per-request socket
/// and no legacy `/v1/ai/chat/ws` fallback in this client: one socket per
/// session carries everything, multiplexed by `req_id`. (The backend keeps
/// `/v1/ai/chat/ws` only so older app builds still work.)
class WebSocketChatService {
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
      yield const ChatStreamEvent.error(
        'Could not establish a connection to the server. '
        'Please check your internet connection and try again.',
      );
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
  }) async* {
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
    };

    // Cache a large message server-side under a client-issued id so later
    // passes of this turn can reference it instead of re-uploading the text.
    // The message still goes up in full this once (the server needs it now).
    if (registry.shouldCache(message)) {
      payload['message_cache_id'] = registry.register(message);
    }

    if (history != null && history.isNotEmpty) {
      payload['history'] = _foldHistoryRefs(history, registry);
    }
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      payload['system_prompt'] = systemPrompt;
    }
    if (reasoningEffort != null) {
      payload['reasoning_effort'] = reasoningEffort;
    }
    if (images != null && images.isNotEmpty) {
      final base64Images = await _convertImagesToBase64(images);
      if (base64Images.isNotEmpty) {
        // Images are the heaviest payload and, because history is text-only,
        // get re-sent on every tool pass. Send each in full ONCE (tagged with a
        // parallel cache id so the server stores it), then reference it by id on
        // later passes — turning megabytes of repeated base64 into a short ref.
        final fullImages = <String>[];
        final fullImageIds = <String>[];
        final imageRefs = <String>[];
        for (final img in base64Images) {
          final ref = registry.refFor(img);
          if (ref != null) {
            imageRefs.add(ref);
          } else {
            fullImages.add(img);
            fullImageIds.add(registry.register(img));
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
    }

    // Route through the per-chatId tracker so two concurrent chat
    // streams for the same chat (e.g. title generation racing the
    // main response) can never interleave into the same UI buffer.
    //
    // The backend occasionally returns a transient routing error (e.g.
    // "Model 'X' is not available on Fireworks AI." or "No provider
    // selected") on the synthesis pass right after tool calls succeed;
    // re-issuing the identical request normally works. Retry once,
    // silently, but only before any content has streamed. (Carried over
    // from the removed legacy path so this self-heal isn't lost.)
    var retriedTransient = false;
    var yieldedContent = false;
    while (true) {
      var shouldRetry = false;
      await for (final event in MultiplexSession.chatForChat(
        chatId: chatId,
        payload: payload,
      )) {
        if (event is ContentEvent || event is ReasoningEvent) {
          yieldedContent = true;
          yield event;
        } else if (event is ErrorEvent) {
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
    }
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
          return <String, dynamic>{'role': role, 'cache_ref': ref};
        }
      }
      return entry;
    }).toList();
  }

  /// Convert image storage paths or existing Base64 URLs to Base64 data URLs.
  /// This is called on-the-fly when sending to AI - images are NOT stored as Base64.
  static Future<List<String>> _convertImagesToBase64(
    List<String> imagePaths,
  ) async {
    final base64Images = <String>[];

    for (final path in imagePaths) {
      try {
        // Check if already a Base64 data URL (legacy support)
        if (path.startsWith('data:image/')) {
          base64Images.add(path);
          continue;
        }

        // Storage path - download, decrypt, and convert to Base64
        final bytes = await ImageStorageService.downloadAndDecryptImage(path);
        final base64 = base64Encode(bytes);
        base64Images.add('data:image/jpeg;base64,$base64');
      } catch (e) {
        if (kDebugMode) {
          debugPrint('⚠️ Failed to convert image to Base64: $path - $e');
        }
        // Skip failed images
      }
    }

    return base64Images;
  }
}
