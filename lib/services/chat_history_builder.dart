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
    final bool shouldIncludeImages = includeRecentImages || includeAllImages;

    // The stored context of every user message, read once.
    final contexts = <TurnPromptContext?>[
      for (final message in messages)
        message['sender'] == 'user'
            ? TurnPromptContext.decode(PromptContextLedger.contextOf(message))
            : null,
    ];
    PromptState? snapshot;
    for (final context in contexts) {
      if (context?.snapshot != null) {
        snapshot = context!.snapshot;
        break;
      }
    }
    PromptState? effective = snapshot;
    // Frozen per chat with the snapshot: whether earlier turns' tool rounds
    // are replayed. A chat without one follows the setting.
    final bool replayTools = snapshot?.toolHistory ?? includeToolResults;
    final Set<int> droppedTranscripts = replayTools
        ? _droppedTranscripts(contexts)
        : const <int>{};

    // The pending-turn check: the last user message's entries, and whether
    // anything answered it.
    var lastUserGroupStart = -1;
    var lastUserTexts = const <String>[];
    var lastIsUser = false;
    // Whether the user message before the next assistant message had its
    // tool rounds replayed: that assistant message then carries no
    // flattened `<previous_tool_results>` block.
    var roundsReplayed = false;

    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final String? sender = message['sender'];
      final String? text = message['text'];

      if (sender == 'user') {
        final context = contexts[i];
        if (context?.state != null) {
          effective = context!.state;
        } else if (context?.stateDiff != null) {
          effective = (effective ?? const PromptState()).applyDiff(
            context!.stateDiff!,
          );
        }
        // Document attachments live in `message['attachments']` (their
        // markdown body), never in `message['text']` — which stores only the
        // display line ("Documents: foo.txt"). Fold the bodies back in so an
        // attached file stays in context for every later turn, not just the
        // turn it was sent on. A turn that stored what it sent replays
        // exactly that (`Document: … User query: …`).
        final String foldedText = _foldAttachmentsIntoText(message, text);
        final String? sentText = context?.sent == null
            ? null
            : expandDocBodies(
                context!.sent!,
                documentBodies(message['attachments']),
              ).trim();
        final String userText = sentText ?? foldedText;

        final bool hasImages =
            message['images'] != null && message['images']!.isNotEmpty;
        final String modelText = renderUserTurnForModel(
          text: userText,
          sentAt: message['sentAt'],
          notes: context?.notes ?? const <String>[],
        );

        final groupStart = history.length;
        var added = false;
        if (shouldIncludeImages && hasImages) {
          final content = userContentWithImages(
            modelText,
            _imageUrls(message['images']!),
          );
          if (content.isNotEmpty) {
            history.add({'role': 'user', 'content': content});
            added = true;
          }
        } else if (userText.trim().isNotEmpty) {
          history.add({'role': 'user', 'content': modelText});
          added = true;
        }

        final transcript = context?.transcript;
        roundsReplayed = false;
        if (replayTools &&
            transcript != null &&
            transcript.isNotEmpty &&
            !droppedTranscripts.contains(i)) {
          // The turn's tool rounds as they were sent. They hold its skill
          // bodies at the place they were loaded.
          for (final entry in transcript) {
            history.add(_cloneEntry(entry));
          }
          roundsReplayed = true;
        } else if (context != null &&
            context.hasTranscript &&
            droppedTranscripts.contains(i)) {
          // Rounds no longer replayed (token budget): a marker row for each
          // skill they loaded, so the model knows to load it again.
          final names = <String>[
            ...context.transcriptSkillNames,
            for (final skill in context.skills)
              if (!context.transcriptSkillNames.contains(skill.name))
                skill.name,
          ];
          for (final name in names) {
            history.add({'role': 'user', 'content': skillDroppedMarker(name)});
          }
        } else {
          for (final skill in context?.skills ?? const <SkillContent>[]) {
            history.add({
              'role': 'user',
              'content': skillContentMessage(skill.name, skill.body),
            });
          }
        }
        if (added || history.length > groupStart) {
          lastUserGroupStart = groupStart;
          final display = (text ?? '').trim();
          // A message with attachments displays "<attachments line>\n\n
          // <input>" (MessageCompositionService); the callers pass the input.
          final split = display.indexOf('\n\n');
          final hasAttachments =
              (message['attachments']?.isNotEmpty ?? false) || hasImages;
          lastUserTexts = <String>[
            foldedText.trim(),
            display,
            ?sentText,
            if (hasAttachments && split >= 0)
              display.substring(split + 2).trim(),
          ];
          lastIsUser = true;
        }
      } else if (sender == 'ai' || sender == 'assistant') {
        // Prior tool calls + results ride along so a follow-up question that
        // needs the same data does not re-run the tools. A turn whose rounds
        // were replayed above already holds them.
        final assistantContent = formatAssistantContent(
          message,
          includeReasoning: includeReasoning,
          includeToolResults: replayTools && !roundsReplayed,
        );
        roundsReplayed = false;
        if (assistantContent == null) continue;
        history.add({'role': 'assistant', 'content': assistantContent});
        lastIsUser = false;
      }
    }

    // Removes the turn being sent right now if the caller's list already
    // contained it. Mobile appends the user bubble to its message list for
    // the UI and then hands that same list over; desktop builds the history
    // first. A *trailing* user message can only be the pending turn, because
    // anything said earlier has an assistant entry after it. All of its
    // entries go (a stale context of a resent message may have added rounds
    // or skills after it).
    final pending = pendingUserText.trim();
    if (pending.isNotEmpty &&
        lastIsUser &&
        lastUserGroupStart >= 0 &&
        lastUserTexts.contains(pending)) {
      history.removeRange(lastUserGroupStart, history.length);
    }

    HistoryPromptContext.attach(
      history,
      HistoryPromptContext(
        snapshot: snapshot,
        effective: effective,
        toolHistory: replayTools,
      ),
    );
    return history;
  }

  /// Characters of replayed tool rounds a history may carry. Over it, the
  /// rounds of the oldest turns are no longer replayed, cut in steps of
  /// half the budget, so the cut point (one prompt-cache miss) moves rarely.
  @visibleForTesting
  static const int transcriptBudgetChars = kTranscriptBudgetChars;

  /// The indexes of the user messages whose tool rounds are not replayed.
  /// Depends on the stored transcripts alone: the same chat gives the same
  /// set, and the set only grows when the total passes the next step.
  static Set<int> _droppedTranscripts(List<TurnPromptContext?> contexts) {
    final sizes = <int, int>{};
    var total = 0;
    for (var i = 0; i < contexts.length; i++) {
      // A stored stub of rounds too large to keep counts with its size.
      final size = contexts[i]?.transcriptSize ?? 0;
      if (size <= 0) continue;
      sizes[i] = size;
      total += size;
    }
    if (total <= transcriptBudgetChars) return const <int>{};
    const step = transcriptBudgetChars ~/ 2;
    final cut = step * ((total - transcriptBudgetChars + step - 1) ~/ step);
    final dropped = <int>{};
    var before = 0;
    for (final entry in sizes.entries) {
      if (before >= cut) break;
      dropped.add(entry.key);
      before += entry.value;
    }
    return dropped;
  }

  static Map<String, dynamic> _cloneEntry(Map<String, dynamic> entry) =>
      jsonDecode(jsonEncode(entry)) as Map<String, dynamic>;

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
