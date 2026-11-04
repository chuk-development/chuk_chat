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
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
import 'package:chuk_chat/utils/input_validator.dart';
import 'package:chuk_chat/utils/tool_history_formatter.dart';

class ChatHistoryBuilder {
  ChatHistoryBuilder._();

  /// Resolved base64 data URLs, keyed by storage path. Shared by both
  /// platforms — there is no reason for two caches of the same downloads.
  /// Least recently used first; bounded by characters, not entries, because
  /// a chat now sends all of its images, not the last ten.
  static final Map<String, String> _imageBase64Cache = <String, String>{};
  static int _imageCacheChars = 0;
  static const int _maxImageCacheChars = 32000000;

  /// Builds the `history` array for a chat request.
  ///
  /// [pendingUserText] is the turn being sent *now*. It travels in the
  /// request's `message` field and the server appends it itself, so it must
  /// not appear here as well.
  ///
  /// The result is a prefix of the next turn's history, byte for byte, so
  /// the provider's prompt cache hits (docs/GOTCHAS.md, "Prompt cache: keep
  /// the prefix stable"):
  ///
  /// * A user message is rendered with its stored `[Sent: …]` line and the
  ///   notes of its `modelContext` (prompt_context.dart), and a skill loaded
  ///   in its turn follows it as a `<skill_content>` message.
  /// * Every image of every turn is included (no moving "last N turns"
  ///   window). Provider limits are applied at send time by [ImageBudget],
  ///   which replaces the OLDEST images in large steps.
  /// * The chat's frozen prompt inputs are attached to the returned list
  ///   ([HistoryPromptContext]) for the tool loop.
  ///
  /// [includeRecentImages] and [includeAllImages] both turn images on; a
  /// moving window of recent images changed the history on every turn.
  static Future<List<Map<String, dynamic>>> build({
    required List<Map<String, String>> messages,
    required String pendingUserText,
    bool includeRecentImages = true,
    bool includeAllImages = false,
    bool includeReasoning = false,
    bool includeToolResults = true,
  }) async {
    final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];
    // The text each entry was made from, before the `[Sent: …]` line and the
    // notes: what the pending-turn check compares against.
    final List<String?> rawTexts = <String?>[];

    final bool shouldIncludeImages = includeRecentImages || includeAllImages;
    PromptState? snapshot;
    PromptState? effective;

    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final String? sender = message['sender'];
      final String? text = message['text'];

      if (sender == 'user') {
        // Document attachments live in `message['attachments']` (their markdown
        // body), never in `message['text']` — which stores only the display
        // line ("Documents: foo.txt"). Fold the bodies back in so an attached
        // file stays in context for every later turn, not just the turn it was
        // sent on. Without this, "solve it" three turns later reaches a model
        // that can no longer see the document.
        final String userText = _foldAttachmentsIntoText(message, text);
        final context = TurnPromptContext.decode(
          PromptContextLedger.contextOf(message),
        );
        if (context?.snapshot != null && snapshot == null) {
          snapshot = context!.snapshot;
          effective = context.snapshot;
        }
        if (context?.state != null) effective = context!.state;

        final bool hasImages =
            message['images'] != null && message['images']!.isNotEmpty;
        final String modelText = renderUserTurnForModel(
          text: userText,
          sentAt: message['sentAt'],
          notes: context?.notes ?? const <String>[],
        );

        if (shouldIncludeImages && hasImages) {
          final content = <Map<String, dynamic>>[];
          if (modelText.isNotEmpty) {
            content.add({'type': 'text', 'text': modelText});
          }
          // The storage path, not the bytes: the send applies the
          // provider's limits first and loads only the images it keeps
          // (ImageBudget.apply, called by WebSocketChatService).
          for (final url in _imageUrls(message['images']!)) {
            content.add({
              'type': 'image_url',
              'image_url': {'url': url},
            });
          }
          if (content.isNotEmpty) {
            history.add({'role': 'user', 'content': content});
            rawTexts.add(userText.trim());
          }
        } else if (userText.trim().isNotEmpty) {
          history.add({'role': 'user', 'content': modelText});
          rawTexts.add(userText.trim());
        }
        for (final skill in context?.skills ?? const <SkillContent>[]) {
          history.add({
            'role': 'user',
            'content': skillContentMessage(skill.name, skill.body),
          });
          rawTexts.add(null);
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
        rawTexts.add(null);
      }
    }

    _dropPendingUserTurn(history, rawTexts, pendingUserText);
    HistoryPromptContext.attach(
      history,
      HistoryPromptContext(snapshot: snapshot, effective: effective),
    );
    return history;
  }

  /// Prepends any document attachments' markdown bodies to a user turn's text,
  /// mirroring how [MessageCompositionService] builds the prompt on send. The
  /// stored `message['text']` is only the display line; the bodies live in
  /// `message['attachments']` as JSON. Returns the display text unchanged when
  /// there are no document attachments.
  @visibleForTesting
  static String foldAttachmentsIntoText(
    Map<String, String> message,
    String? text,
  ) => _foldAttachmentsIntoText(message, text);

  static String _foldAttachmentsIntoText(
    Map<String, String> message,
    String? text,
  ) {
    final String displayText = text?.trim() ?? '';
    final String? attachmentsJson = message['attachments'];
    if (attachmentsJson == null || attachmentsJson.trim().isEmpty) {
      return displayText;
    }

    final List<String> sections = <String>[];
    try {
      final decoded = jsonDecode(attachmentsJson);
      if (decoded is List) {
        for (final entry in decoded) {
          if (entry is! Map) continue;
          final content = entry['markdownContent'];
          if (content is! String || content.isEmpty) continue;
          final rawName = entry['fileName']?.toString() ?? 'document';
          // This text is the model's history, not a markdown-rendered bubble,
          // so the name is only path-sanitised — markdown-escaping it here
          // would show the model `note\.txt` while the body right below it
          // goes in raw.
          final safeName = InputValidator.sanitizeFileName(rawName);
          sections.add('Document: "$safeName"\n```\n$content\n```');
        }
      }
    } catch (_) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatHistoryBuilder] attachments JSON parse failed');
      }
      return displayText;
    }

    if (sections.isEmpty) return displayText;

    final String docBlock = sections.join('\n\n');
    return displayText.isEmpty ? docBlock : '$docBlock\n\n$displayText';
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
  ///
  /// Compared on the text before the `[Sent: …]` line and the notes
  /// ([rawTexts]), which the pending text does not carry yet.
  static void _dropPendingUserTurn(
    List<Map<String, dynamic>> history,
    List<String?> rawTexts,
    String pendingUserText,
  ) {
    final pending = pendingUserText.trim();
    if (pending.isEmpty || history.isEmpty) return;

    final last = history.last;
    if (last['role'] == 'user' && rawTexts.last == pending) {
      history.removeLast();
      rawTexts.removeLast();
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

  /// The image references of a message (storage paths or data URLs), in
  /// order.
  static List<String> _imageUrls(String imagesJson) {
    try {
      final decoded = jsonDecode(imagesJson);
      if (decoded is! List) return const <String>[];
      return [
        for (final img in decoded)
          if (img.toString().isNotEmpty) img.toString(),
      ];
    } catch (_) {
      if (kDebugMode) {
        debugPrint('⚠️ [ChatHistoryBuilder] images JSON parse failed');
      }
      return const <String>[];
    }
  }

  /// Resolves a JSON-encoded list of image storage paths to base64 data URLs.
  /// An image that cannot be loaded is left out.
  static Future<List<String>> resolveHistoryImages(String imagesJson) async {
    final dataUrls = <String>[];
    for (final url in _imageUrls(imagesJson)) {
      final dataUrl = await resolveImageDataUrl(url);
      if (dataUrl != null) dataUrls.add(dataUrl);
    }
    return dataUrls;
  }

  /// The data URL of one image: a data URL as it is, a storage path
  /// downloaded, decrypted and labelled with its real type. Null when it
  /// cannot be loaded. The same image always gives the same bytes (the
  /// history and the turn that sends it use this one function).
  static Future<String?> resolveImageDataUrl(String path) async {
    if (path.isEmpty) return null;
    if (path.startsWith('data:image/')) return path;

    final cached = _imageBase64Cache.remove(path);
    if (cached != null) {
      _imageBase64Cache[path] = cached; // most recently used
      return cached;
    }

    try {
      final bytes = await ImageStorageService.downloadAndDecryptImage(path);
      // Sniff the real type. Hardcoding image/jpeg (as the mobile copy
      // did) mislabels every PNG and WebP attachment.
      final mimeType = ChatUiHelpers.detectImageMimeType(bytes);
      final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
      _imageBase64Cache[path] = dataUrl;
      _imageCacheChars += dataUrl.length;
      while (_imageCacheChars > _maxImageCacheChars &&
          _imageBase64Cache.length > 1) {
        final oldest = _imageBase64Cache.keys.first;
        _imageCacheChars -= _imageBase64Cache.remove(oldest)!.length;
      }
      return dataUrl;
    } catch (_) {
      // Non-critical: the image becomes a placeholder. The exception text
      // can carry the storage path, so it is not echoed into the log.
      if (kDebugMode) {
        debugPrint('⚠️ [ChatHistoryBuilder] image resolve failed');
      }
      return null;
    }
  }
}
