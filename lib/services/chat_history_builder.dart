// lib/services/chat_history_builder.dart
//
// The single source of truth for turning the on-screen message list into the
// `history` array of an outgoing chat request.
//
// This used to exist twice — once in `streaming_message_handler.dart` for
// mobile, once in `desktop_send_logic.dart` for desktop — as a line-for-line
// copy. The copies then drifted, and each drift was a shipped bug:
//
//   * Commit 84aa1f6 removed the duplicated current user turn from the desktop
//     copy only. Mobile kept sending `{message: "hi", history: [… "hi"]}`, so
//     every model was told the user had said it twice.
//   * Desktop learned to sniff the real image MIME type; mobile kept labelling
//     every attachment `image/jpeg`, so a PNG went out mislabelled.
//
// Anything platform-specific (background execution, foreground service, the
// widgets themselves) stays with the platform. Deciding what the model is told
// is not platform-specific and must not be forked again.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/utils/tool_history_formatter.dart';

class ChatHistoryBuilder {
  ChatHistoryBuilder._();

  /// Image window when only recent images are included.
  static const int _recentImageWindow = 10;

  /// Ceiling on images and on total base64 characters per request.
  static const int _maxHistoryImages = 10;
  static const int _maxHistoryImageChars = 1500000;

  /// Resolved base64 data URLs, keyed by storage path. Shared by both
  /// platforms — there is no reason for two caches of the same downloads.
  static final Map<String, String> _imageBase64Cache = <String, String>{};
  static const int _maxImageCacheSize = 10;

  /// Builds the `history` array for a chat request.
  ///
  /// [pendingUserText] is the turn being sent *now*. It travels in the
  /// request's `message` field and the server appends it itself, so it must
  /// not appear here as well.
  static Future<List<Map<String, dynamic>>> build({
    required List<Map<String, String>> messages,
    required String pendingUserText,
    bool includeRecentImages = true,
    bool includeAllImages = false,
    bool includeReasoning = false,
    bool includeToolResults = true,
  }) async {
    final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];

    final bool shouldIncludeImages = includeRecentImages || includeAllImages;
    final int imageWindow = includeAllImages
        ? messages.length
        : _recentImageWindow;
    var remainingImageCount = _maxHistoryImages;
    var remainingImageChars = _maxHistoryImageChars;

    // Which user messages fall inside the image window, counting from the end.
    final Set<int> imageEligibleIndices = <int>{};
    if (shouldIncludeImages) {
      var userMsgCount = 0;
      for (var i = messages.length - 1; i >= 0; i--) {
        if (messages[i]['sender'] == 'user') {
          userMsgCount++;
          if (userMsgCount <= imageWindow) {
            imageEligibleIndices.add(i);
          }
        }
      }
    }

    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final String? sender = message['sender'];
      final String? text = message['text'];

      if (sender == 'user') {
        final bool hasImages =
            message['images'] != null && message['images']!.isNotEmpty;
        final bool shouldAddImages =
            shouldIncludeImages &&
            hasImages &&
            imageEligibleIndices.contains(i);

        if (shouldAddImages) {
          final content = <Map<String, dynamic>>[];
          if (text != null && text.trim().isNotEmpty) {
            content.add({'type': 'text', 'text': text});
          }

          final imageDataUrls = await resolveHistoryImages(message['images']!);
          var addedImages = 0;
          for (final dataUrl in imageDataUrls) {
            if (remainingImageCount <= 0) break;
            if (dataUrl.length > remainingImageChars) break;
            content.add({
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            });
            remainingImageCount--;
            remainingImageChars -= dataUrl.length;
            addedImages++;
          }

          final skippedImages = imageDataUrls.length - addedImages;
          if (skippedImages > 0) {
            content.add({
              'type': 'text',
              'text':
                  '[$skippedImages image(s) omitted from history due request '
                  'size limits.]',
            });
          }
          if (content.isNotEmpty) {
            history.add({'role': 'user', 'content': content});
          }
        } else if (text != null && text.trim().isNotEmpty) {
          history.add({'role': 'user', 'content': text});
        }
      } else if (sender == 'ai' || sender == 'assistant') {
        // Prior tool calls + results ride along so a follow-up question that
        // needs the same data does not re-run the tools.
        final assistantContent = formatAssistantContent(
          message,
          includeReasoning: includeReasoning,
          includeToolResults: includeToolResults,
        );
        if (assistantContent == null) continue;
        history.add({'role': 'assistant', 'content': assistantContent});
      }
    }

    _dropPendingUserTurn(history, pendingUserText);
    return history;
  }

  /// Removes the turn being sent right now if the caller's list already
  /// contained it.
  ///
  /// Mobile appends the user bubble to its message list for the UI and then
  /// hands that same list over; desktop builds the history first. Rather than
  /// depend on callers getting the ordering right, the invariant is enforced
  /// here: a *trailing* user entry can only be the pending turn, because
  /// anything said earlier has an assistant entry after it. The same text
  /// legitimately sent twice in a row therefore keeps its answered copy.
  static void _dropPendingUserTurn(
    List<Map<String, dynamic>> history,
    String pendingUserText,
  ) {
    final pending = pendingUserText.trim();
    if (pending.isEmpty || history.isEmpty) return;

    final last = history.last;
    if (last['role'] == 'user' && entryText(last) == pending) {
      history.removeLast();
    }
  }

  /// Plain text of a history entry, for both the bare-string and the
  /// multimodal `[{type: text}, {type: image_url}, …]` forms.
  @visibleForTesting
  static String entryText(Map<String, dynamic> entry) {
    final content = entry['content'];
    if (content is String) return content.trim();
    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map && part['type'] == 'text') {
          buffer.write(part['text']?.toString() ?? '');
        }
      }
      return buffer.toString().trim();
    }
    return '';
  }

  /// Resolves a JSON-encoded list of image storage paths to base64 data URLs.
  static Future<List<String>> resolveHistoryImages(String imagesJson) async {
    final List<String> dataUrls = <String>[];
    try {
      final decoded = jsonDecode(imagesJson);
      if (decoded is! List) return dataUrls;

      for (final img in decoded) {
        final path = img.toString();
        if (path.isEmpty) continue;

        if (path.startsWith('data:image/')) {
          dataUrls.add(path);
          continue;
        }

        final cached = _imageBase64Cache[path];
        if (cached != null) {
          dataUrls.add(cached);
          continue;
        }

        try {
          final bytes = await ImageStorageService.downloadAndDecryptImage(path);
          // Sniff the real type. Hardcoding image/jpeg (as the mobile copy
          // did) mislabels every PNG and WebP attachment.
          final mimeType = ChatUiHelpers.detectImageMimeType(bytes);
          final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';

          if (_imageBase64Cache.length >= _maxImageCacheSize) {
            _imageBase64Cache.remove(_imageBase64Cache.keys.first);
          }
          _imageBase64Cache[path] = dataUrl;
          dataUrls.add(dataUrl);
        } catch (e) {
          if (kDebugMode) {
            debugPrint('⚠️ [ChatHistoryBuilder] image resolve failed: $e');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatHistoryBuilder] images JSON parse failed: $e');
      }
    }
    return dataUrls;
  }

  @visibleForTesting
  static void clearImageCacheForTest() => _imageBase64Cache.clear();
}
